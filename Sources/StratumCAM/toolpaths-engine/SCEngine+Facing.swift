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
                             angle: Double = 0,
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
                                   direction: direction,
                                   angle: angle)
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
                         direction: SC.CutDirection,
                         angle: Double = 0) -> [[SC.Segment]] {

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

        // A rotated raster only makes sense when the tool-center area is a real rectangle;
        // if the tool is as wide as the footprint on either axis the path has collapsed to
        // a line and the angle has nothing to rotate, so those fall back to the straight rows.
        let normalizedAngle = angle.truncatingRemainder(dividingBy: 360)
        let isAxisAligned = abs(normalizedAngle) < 1e-9 || abs(abs(normalizedAngle) - 360) < 1e-9
        if !isAxisAligned,
           area.maxX - area.minX > 1e-9,
           area.maxY - area.minY > 1e-9 {
            return angledFacingScanlines(area: area,
                                         stepover: stepover,
                                         direction: direction,
                                         angleDegrees: normalizedAngle)
        }

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

    /// The `facingScanlines` raster rotated by `angleDegrees` (counter-clockwise from +X).
    ///
    /// The rows run along `u = (cos a, sin a)` and are spaced `stepover` apart along the
    /// perpendicular `v = (-sin a, cos a)`, from the area corner with the lowest `v` to the
    /// one with the highest, so the first and last rows always touch a corner and the pass
    /// count follows the same whole-number snapping as the straight version. Each row is
    /// clipped to `area` (the tool-center rectangle), which keeps the cutter inside the cut
    /// area at any angle. Rows alternate direction like the straight raster; the first one
    /// runs along +u for `.climb`, so a rotated path is the 0 degree path rotated by `a`.
    private func angledFacingScanlines(area: (minX: Double, maxX: Double, minY: Double, maxY: Double),
                                       stepover: Double,
                                       direction: SC.CutDirection,
                                       angleDegrees: Double) -> [[SC.Segment]] {
        let radians = angleDegrees * Double.pi / 180
        let ux = cos(radians), uy = sin(radians)
        let vx = -uy, vy = ux

        let corners = [(area.minX, area.minY), (area.maxX, area.minY),
                       (area.maxX, area.maxY), (area.minX, area.maxY)]
        let vValues = corners.map { $0.0 * vx + $0.1 * vy }
        guard let vMin = vValues.min(), let vMax = vValues.max() else {
            return []
        }

        let span = vMax - vMin
        guard span > 1e-9 else {
            return []
        }
        let rawSteps = span / stepover
        let stepCount = abs(rawSteps.rounded() - rawSteps) < 1e-9
            ? max(1, Int(rawSteps.rounded()))
            : max(1, Int(rawSteps.rounded(.up)))
        let rowCount = stepCount + 1

        /// The `t` range over which `origin + t * (ux, uy)` stays inside `area` (Liang-Barsky),
        /// or `nil` when the line misses it or only grazes a corner.
        func clippedRange(originX: Double, originY: Double) -> (Double, Double)? {
            var tMin = -Double.infinity, tMax = Double.infinity

            func clip(origin: Double, delta: Double, lo: Double, hi: Double) -> Bool {
                if abs(delta) < 1e-12 {
                    return origin >= lo - 1e-9 && origin <= hi + 1e-9
                }
                var t0 = (lo - origin) / delta
                var t1 = (hi - origin) / delta
                if t0 > t1 {
                    swap(&t0, &t1)
                }
                tMin = Swift.max(tMin, t0)
                tMax = Swift.min(tMax, t1)
                return tMin <= tMax
            }

            guard clip(origin: originX, delta: ux, lo: area.minX, hi: area.maxX),
                  clip(origin: originY, delta: uy, lo: area.minY, hi: area.maxY),
                  tMax - tMin > 1e-9 else {
                return nil
            }
            return (tMin, tMax)
        }

        var rows: [[SC.Segment]] = []
        var forward = (direction == .climb)

        for i in 0..<rowCount {
            let v = (i == rowCount - 1) ? vMax : vMin + stepover * Double(i)
            guard let range = clippedRange(originX: v * vx, originY: v * vy) else {
                continue
            }
            let from = forward ? range.0 : range.1
            let to = forward ? range.1 : range.0
            let start = CGPoint(x: v * vx + from * ux, y: v * vy + from * uy)
            let end = CGPoint(x: v * vx + to * ux, y: v * vy + to * uy)

            rows.append([.line(start: start, end: end)])
            forward.toggle()
        }

        return rows
    }
}
