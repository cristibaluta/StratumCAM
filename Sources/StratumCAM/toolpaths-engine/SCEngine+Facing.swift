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

    /// Generates the raster scanline geometry for `.facing`: parallel horizontal
    /// passes spaced `stepover` apart, each spanning the full width of
    /// `facingArea(stock:extensionLength:)` -- geometry only, no waypoints yet. That's
    /// left to a future `buildFacingWaypoints` wrapper (Step 2A.2), same shape as
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
    /// The last row is snapped exactly onto the footprint's far edge rather than
    /// landing short or overshooting -- same fencepost convention `rasterScanlines`
    /// and `calculateZPasses` use.
    ///
    /// Each row is returned as a single-segment `[SC.Segment]`, matching
    /// `rasterScanlines`' per-row shape, so a future waypoint wrapper can reuse
    /// `chainedRingSegments` to link rows exactly the way pocketing's raster does.
    func facingScanlines(stock: SC.Stock,
                         extensionLength: Double,
                         stepover: Double,
                         direction: SC.CutDirection) -> [[SC.Segment]] {

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
}
