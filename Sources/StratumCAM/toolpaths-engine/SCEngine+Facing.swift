//
//  SCEngine+Facing.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// Turns `facingScanlines`' rows into an actual toolpath: chains them with
    /// `chainedRingSegments` (the same row-linking helper pocketing's raster uses --
    /// a list of rows is the same "segment groups needing connecting transitions"
    /// shape either way) and wraps the result with `buildWaypoints`' rapid/plunge/
    /// retract pass.
    func buildFacingToolpath(for contour: SC.Contour,
                             tool: SC.ToolParams,
                             settings: SC.MachineSettings,
                             direction: SC.CutDirection,
                             extensionLength: Double,
                             operation: SC.MachiningOperation) throws -> SC.OutputToolpath {

        guard let area = facingArea(for: contour, extensionLength: extensionLength),
              area.maxX - area.minX > 1e-9,
              area.maxY - area.minY > 1e-9 else {
            throw SC.Error.invalidContour
        }

        let rows = facingScanlines(within: contour,
                                   extensionLength: extensionLength,
                                   tool: tool,
                                   settings: settings,
                                   direction: direction)
        guard !rows.isEmpty else {
            throw SC.Error.geometryCollapsed
        }

        let toolpathSegments = chainedRingSegments(rows)
        guard !toolpathSegments.isEmpty else {
            throw SC.Error.geometryCollapsed
        }

        // One lap of the rows per Z layer, `settings.cutting.stepdown` deep each (a single
        // pass when the stepdown is 0 or at least the depth). Every layer starts and ends with
        // its own rapid at safe Z, so the layers chain without extra connecting moves.
        let zDepths = EngineTools.calculateZPasses(targetDepth: settings.targetDepth, stepdown: settings.cutting.stepdown)
        let passes = zDepths.enumerated().map { index, z in
            SC.ToolpathPass(passIndex: index,
                            depthZ: z,
                            waypoints: buildWaypoints(for: toolpathSegments, atZ: z, settings: settings))
        }

        return SC.OutputToolpath(operation: operation, tool: tool, settings: settings, passes: passes)
    }

    /// Folds every selected contour into one closed rectangle spanning the union of their
    /// bounding boxes, so `.facing` machines the whole selection with a single toolpath
    /// instead of one per shape. `nil` when there is nothing with a finite extent to
    /// combine (the caller then leaves the contours alone and per-contour validation
    /// reports the problem).
    func facingBoundingContour(of contours: [SC.Contour]) -> SC.Contour? {
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity

        for contour in contours {
            let box = contour.linearizedSegments.boundingBox
            guard box.minX.isFinite, box.maxX.isFinite, box.minY.isFinite, box.maxY.isFinite else {
                continue
            }
            minX = Swift.min(minX, box.minX)
            maxX = Swift.max(maxX, box.maxX)
            minY = Swift.min(minY, box.minY)
            maxY = Swift.max(maxY, box.maxY)
        }
        guard minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite else {
            return nil
        }

        let bottomLeft = SIMD2<Double>(minX, minY), bottomRight = SIMD2<Double>(maxX, minY)
        let topRight = SIMD2<Double>(maxX, maxY), topLeft = SIMD2<Double>(minX, maxY)
        return SC.Contour(entities: [
            .init(geometry: .line(a: bottomLeft, b: bottomRight), reversed: false),
            .init(geometry: .line(a: bottomRight, b: topRight), reversed: false),
            .init(geometry: .line(a: topRight, b: topLeft), reversed: false),
            .init(geometry: .line(a: topLeft, b: bottomLeft), reversed: false)
        ], isClosed: true)
    }

    /// The XY region `.facing` is allowed to cut: the selected contour's own axis-aligned
    /// bounding box, grown by `extensionLength` on every side. This is the boundary of the
    /// *material removed* -- the cutter's edge never crosses it. `extensionLength` is the
    /// operation's own explicit "how far past the part" parameter (per its doc comment on
    /// `MachiningOperation.facing`); with the default of 0 the tool stays inside the bounding
    /// box. Not the tool-center path -- see `facingToolCenterArea`.
    func facingArea(for contour: SC.Contour, extensionLength: Double) -> (minX: Double, maxX: Double, minY: Double, maxY: Double)? {
        let box = contour.linearizedSegments.boundingBox
        guard box.minX.isFinite, box.maxX.isFinite, box.minY.isFinite, box.maxY.isFinite else {
            return nil
        }

        return (minX: box.minX - extensionLength,
               maxX: box.maxX + extensionLength,
               minY: box.minY - extensionLength,
               maxY: box.maxY + extensionLength)
    }

    /// The area the tool *center* travels so the cutter's edge stays inside `facingArea`.
    /// The footprint is inset by the tool radius on every side; the first/last rows and the
    /// row ends therefore put the cutter's edge exactly on the footprint boundary instead of
    /// a radius past it. On an axis where the footprint is narrower than the tool the cutter
    /// cannot fit, so the path collapses to the footprint's center line on that axis (the
    /// unavoidable overhang is split evenly on both sides).
    func facingToolCenterArea(for contour: SC.Contour,
                              extensionLength: Double,
                              tool: SC.ToolParams) -> (minX: Double, maxX: Double, minY: Double, maxY: Double)? {
        guard let area = facingArea(for: contour, extensionLength: extensionLength) else {
            return nil
        }
        let radius = max(tool.diameter, 0) / 2

        func inset(_ lo: Double, _ hi: Double) -> (Double, Double) {
            if hi - lo <= 2 * radius {
                let mid = (lo + hi) / 2
                return (mid, mid)
            }
            return (lo + radius, hi - radius)
        }
        let x = inset(area.minX, area.maxX)
        let y = inset(area.minY, area.maxY)
        return (minX: x.0, maxX: x.1, minY: y.0, maxY: y.1)
    }

    /// Row spacing: `CuttingData.stepoverPercentage` of the tool diameter, capped at one full
    /// diameter (rows further apart would leave uncut strips) and floored at 2 %.
    private func facingStepover(for tool: SC.ToolParams, settings: SC.MachineSettings) -> Double {
        let fraction = min(max(settings.cutting.stepoverPercentage, 0.02), 1.0)
        return max(tool.diameter * fraction, 1e-6)
    }

    /// Generates the raster scanline geometry for `.facing`: parallel horizontal
    /// passes spaced `facingStepover(for:settings:)` apart, each spanning the full width
    /// of `facingToolCenterArea(for:extensionLength:tool:)` (the footprint inset by the tool
    /// radius, so the cutter never leaves `facingArea`) -- geometry only, no waypoints yet.
    /// That's left to `buildFacingToolpath` below, same shape as
    /// `buildPocketWaypoints` turning `rasterScanlines`' rows into an actual rapid/
    /// plunge/retract pass.
    func facingScanlines(within contour: SC.Contour,
                         extensionLength: Double,
                         tool: SC.ToolParams,
                         settings: SC.MachineSettings,
                         direction: SC.CutDirection) -> [[SC.Segment]] {

        let stepover = facingStepover(for: tool, settings: settings)
        guard stepover > 1e-6,
              facingArea(for: contour, extensionLength: extensionLength).map({
                  $0.maxX - $0.minX > 1e-9 && $0.maxY - $0.minY > 1e-9
              }) == true,
              let area = facingToolCenterArea(for: contour, extensionLength: extensionLength, tool: tool) else {
            return []
        }

        // The tool-center span can be 0 when the tool is as wide as the footprint (one row /
        // a zero-length row); that is still a valid, if over-wide, cut.
        let span = area.maxY - area.minY
        let stepCount: Int
        if span <= 1e-9 {
            stepCount = 0
        } else {
            // Same whole-number snapping `rasterScanlines`/`calculateZPasses` use: a span
            // that divides evenly by `stepover` shouldn't gain a spurious extra row from
            // float drift.
            let rawSteps = span / stepover
            if abs(rawSteps.rounded() - rawSteps) < 1e-9 {
                stepCount = max(1, Int(rawSteps.rounded()))
            } else {
                stepCount = max(1, Int(rawSteps.rounded(.up)))
            }
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
