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

    /// The XY footprint `.facing` clears: the selected contour's own axis-aligned
    /// bounding box, grown by `extensionLength` on every side so the cutter fully
    /// clears the true part edges (and corners, once the tool's own radius sweeps
    /// past a raster row's endpoint) rather than stopping exactly at the nominal
    /// boundary. Geometry only -- no tool-radius compensation is folded in here,
    /// since `extensionLength` is the operation's own explicit "how far past the
    /// boundary" parameter (per its doc comment on `MachiningOperation.facing`),
    /// not something this function should be second-guessing with its own
    /// additional margin.
    private func facingArea(for contour: SC.Contour, extensionLength: Double) -> (minX: Double, maxX: Double, minY: Double, maxY: Double)? {
        let box = contour.linearizedSegments.boundingBox
        guard box.minX.isFinite, box.maxX.isFinite, box.minY.isFinite, box.maxY.isFinite else {
            return nil
        }

        return (minX: box.minX - extensionLength,
               maxX: box.maxX + extensionLength,
               minY: box.minY - extensionLength,
               maxY: box.maxY + extensionLength)
    }

    /// Row spacing: `CuttingData.stepoverPercentage` of the tool diameter, capped at one full
    /// diameter (rows further apart would leave uncut strips) and floored at 2 %.
    private func facingStepover(for tool: SC.ToolParams, settings: SC.MachineSettings) -> Double {
        let fraction = min(max(settings.cutting.stepoverPercentage, 0.02), 1.0)
        return max(tool.diameter * fraction, 1e-6)
    }

    /// Generates the raster scanline geometry for `.facing`: parallel horizontal
    /// passes spaced `facingStepover(for:settings:)` apart, each spanning the full width
    /// of `facingArea(for:extensionLength:)` -- geometry only, no waypoints yet.
    /// That's left to `buildFacingToolpath` below, same shape as
    /// `buildPocketWaypoints` turning `rasterScanlines`' rows into an actual rapid/
    /// plunge/retract pass.
    private func facingScanlines(within contour: SC.Contour,
                                 extensionLength: Double,
                                 tool: SC.ToolParams,
                                 settings: SC.MachineSettings,
                                 direction: SC.CutDirection) -> [[SC.Segment]] {

        let stepover = facingStepover(for: tool, settings: settings)
        guard stepover > 1e-6, let area = facingArea(for: contour, extensionLength: extensionLength) else {
            return []
        }

        let span = area.maxY - area.minY
        guard span > 1e-9, area.maxX - area.minX > 1e-9 else {
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
