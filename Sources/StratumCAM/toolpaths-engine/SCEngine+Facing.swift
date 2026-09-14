//
//  SCEngine+Facing.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// The XY footprint `.facing` clears: the stock's own top-face rectangle, grown by
    /// `extensionLength` on every side so the cutter fully clears the true stock edges
    /// (and corners, once the tool's own radius sweeps past a raster row's endpoint)
    /// rather than stopping exactly at the nominal stock boundary. Geometry only --
    /// no tool-radius compensation is folded in here, since `extensionLength` is the
    /// operation's own explicit "how far past the boundary" parameter (per its doc
    /// comment on `MachiningOperation.facing`), not something this function should be
    /// second-guessing with its own additional margin.
    ///
    /// - Note (assumption -- flagging per Step 2A.1, since `Stock` has no prior
    ///   consumer in the codebase to confirm this against): `stock.origin` is read as
    ///   the stock's top-face, min-X/min-Y corner, so the rectangle spans
    ///   `origin.x ... origin.x + width` and `origin.y ... origin.y + height`, not a
    ///   center-referenced stock. This matches `origin`'s own doc comment ("WCS G54
    ///   origin") under the common shop convention of touching off G54 at a stock
    ///   corner, and is consistent with `MachineSettings.targetDepth` treating Z=0 as
    ///   the stock's top surface (`origin.z`) rather than its middle. If your stock is
    ///   actually center-referenced, or `origin` marks a different corner, this needs
    ///   revisiting before 2A.2 builds waypoints on top of it.
    func facingArea(stock: SC.Stock, extensionLength: Double) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        (minX: stock.origin.x - extensionLength,
         maxX: stock.origin.x + stock.width + extensionLength,
         minY: stock.origin.y - extensionLength,
         maxY: stock.origin.y + stock.height + extensionLength)
    }

    /// Row spacing for `.facing`, derived from the tool instead of taken as a
    /// caller-supplied parameter.
    ///
    /// Facing has no wall to protect the way a pocket does -- `.pocket` uses
    /// `stepoverPercentage * tool.diameter` (typically ~0.4) to keep radial
    /// engagement low against a wall it's about to trim, but a facing pass is
    /// just a flat-bottom sweep over open ground. There's no finish/chip-load
    /// tradeoff for a caller to tune, so rather than exposing another number to
    /// set, the engine runs the tool at close to its own full diameter.
    ///
    /// `facingStepoverEngagement` (90%) is deliberately just under 100%, not
    /// exactly 100%: at exactly one diameter apart, two adjacent passes' swept
    /// strips only just touch at a shared edge, so a hairline of floating-point
    /// error could leave an unmilled seam running the full length of the row.
    /// 90% keeps a real overlap margin so that can't happen, while still being
    /// close enough to full engagement that facing stays a fast, small-row-count
    /// operation rather than a fine finishing pass.
    private var facingStepoverEngagement: Double { 0.9 }

    func facingStepover(for tool: SC.ToolParams) -> Double {
        max(tool.diameter * facingStepoverEngagement, 1e-6)
    }

    /// Generates the raster scanline geometry for `.facing`: parallel horizontal
    /// passes spaced `facingStepover(for: tool)` apart, each spanning the full width
    /// of `facingArea(stock:extensionLength:)` -- geometry only, no waypoints yet.
    /// That's left to `buildFacingToolpath` (Step 2A.2) below, same shape as
    /// `buildPocketWaypoints` turning `rasterScanlines`' rows into an actual rapid/
    /// plunge/retract pass.
    ///
    /// Unlike pocketing's `rasterScanlines`, there's no boundary to clip against --
    /// facing's footprint is already the plain rectangle `facingArea` computes, so
    /// every row spans its full width directly with no intersection math needed.
    /// Rows run bottom-to-top and alternate direction (boustrophedon), the same
    /// convention `rasterScanlines` uses, so a future waypoint wrapper's connecting
    /// move between rows is a short step rather than a long retrace. `direction`
    /// only decides which way the *first* row travels (`.climb` left-to-right,
    /// `.conventional` right-to-left) -- same as pocketing's raster, there's no wall
    /// cut in a plain rectangular fill for climb/conventional to otherwise apply to.
    ///
    /// The first and last rows are snapped exactly onto the footprint's near/far
    /// edges rather than landing short -- this is also what keeps every corner of
    /// the footprint covered: each edge row's start point sits exactly on that
    /// edge (and exactly on the footprint's corner at its first/last row), so the
    /// tool's own swept disc at that point has zero distance to close, no matter
    /// how wide `facingStepoverEngagement` makes the gap between the interior rows.
    /// The last interior gap is snapped narrower rather than overshooting past the
    /// far edge -- same fencepost convention `rasterScanlines` and
    /// `calculateZPasses` use.
    ///
    /// Each row is returned as a single-segment `[SC.Segment]`, matching
    /// `rasterScanlines`' per-row shape, so `buildFacingToolpath` below can reuse
    /// `chainedRingSegments` to link rows exactly the way pocketing's raster does.
    func facingScanlines(stock: SC.Stock,
                         extensionLength: Double,
                         tool: SC.ToolParams,
                         direction: SC.CutDirection) -> [[SC.Segment]] {

        let stepover = facingStepover(for: tool)
        guard stepover > 1e-6, stock.width > 0, stock.height > 0 else {
            return []
        }

        let area = facingArea(stock: stock, extensionLength: extensionLength)
        let span = area.maxY - area.minY
        guard span > 1e-9 else {
            return []
        }

        // Same whole-number snapping `rasterScanlines`/`calculateZPasses` use: a span
        // that divides evenly by `stepover` shouldn't gain a spurious extra row from
        // float drift.
        let rawSteps = span / stepover
        let epsilon = 1e-9
        let stepCount: Int
        if abs(rawSteps.rounded() - rawSteps) < epsilon {
            stepCount = max(1, Int(rawSteps.rounded()))
        } else {
            stepCount = max(1, Int(rawSteps.rounded(.up)))
        }
        let rowCount = stepCount + 1

        var rows: [[SC.Segment]] = []
        var leftToRight = (direction == .climb)

        for i in 0..<rowCount {
            let y = (i == rowCount - 1) ? area.maxY : area.minY + stepover * Double(i)
            let row: SC.Segment = leftToRight
                ? .line(start: CGPoint(x: area.minX, y: y), end: CGPoint(x: area.maxX, y: y))
                : .line(start: CGPoint(x: area.maxX, y: y), end: CGPoint(x: area.minX, y: y))

            rows.append([row])
            leftToRight.toggle()
        }

        return rows
    }

    // MARK: - Step 2A.2: facing toolpath

    /// Turns `facingScanlines`' rows into an actual toolpath: chains them with
    /// `chainedRingSegments` (the same row-linking helper pocketing's raster uses --
    /// a list of rows is the same "segment groups needing connecting transitions"
    /// shape either way) and wraps the result with `buildWaypoints`' rapid/plunge/
    /// retract pass, exactly the way `.facing`'s own doc comment and this file's
    /// earlier notes said a later wrapper would.
    ///
    /// Single `ToolpathPass` at `-abs(settings.targetDepth)` -- facing is a one-pass
    /// datum operation per `MachiningOperation.facing`'s doc comment, not a
    /// multi-pass Z stepdown like `.pocket`/`.contour`, so there's no
    /// `calculateZPasses` here. Same sign convention `buildDrillingToolpath` uses
    /// for its own single-pass plunge depth.
    ///
    /// `.facing` has no `EntryStrategy` of its own (see `MachiningOperation.facing`'s
    /// parameters), so this always uses the plain straight-down plunge `buildWaypoints`
    /// already provides -- there's no ramp/helix case to route to the way
    /// `buildPocketWaypoints` does for `.pocket`.
    ///
    /// `direction` only decides which way the first scanline row travels (already
    /// resolved by `facingScanlines`, which alternates every row after that); there's
    /// no wall cut in a plain rectangular fill for climb/conventional to otherwise
    /// apply to, same as pocketing's raster.
    func buildFacingToolpath(stock: SC.Stock,
                             tool: SC.ToolParams,
                             settings: SC.MachineSettings,
                             direction: SC.CutDirection,
                             extensionLength: Double,
                             operation: SC.MachiningOperation) -> SC.OutputToolpath? {

        let rows = facingScanlines(stock: stock,
                                   extensionLength: extensionLength,
                                   tool: tool,
                                   direction: direction)
        guard !rows.isEmpty else {
            return nil
        }

        let toolpathSegments = chainedRingSegments(rows)
        guard !toolpathSegments.isEmpty else {
            return nil
        }

        let z = -abs(settings.targetDepth)
        let waypoints = buildWaypoints(for: toolpathSegments, atZ: z, settings: settings)

        let pass = SC.ToolpathPass(passIndex: 0, depthZ: z, waypoints: waypoints)
        return SC.OutputToolpath(operation: operation, tool: tool, settings: settings, passes: [pass])
    }
}
