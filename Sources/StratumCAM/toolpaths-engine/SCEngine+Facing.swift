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
                                   direction: direction)
        guard !rows.isEmpty else {
            throw SC.Error.geometryCollapsed
        }

        let toolpathSegments = chainedRingSegments(rows)
        guard !toolpathSegments.isEmpty else {
            throw SC.Error.geometryCollapsed
        }

        let z = -abs(settings.targetDepth)
        let waypoints = buildWaypoints(for: toolpathSegments, atZ: z, settings: settings)

        let pass = SC.ToolpathPass(passIndex: 0, depthZ: z, waypoints: waypoints)

        return SC.OutputToolpath(operation: operation, tool: tool, settings: settings, passes: [pass])
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

    // TODO: this must be received from settings and capped to 1. from settings it comes as a percentage of tool diam
    private var facingStepoverEngagement: Double { 0.9 }

    private func facingStepover(for tool: SC.ToolParams) -> Double {
        max(tool.diameter * facingStepoverEngagement, 1e-6)
    }

    /// Generates the raster scanline geometry for `.facing`: parallel horizontal
    /// passes spaced `facingStepover(for: tool)` apart, each spanning the full width
    /// of `facingArea(for:extensionLength:)` -- geometry only, no waypoints yet.
    /// That's left to `buildFacingToolpath` below, same shape as
    /// `buildPocketWaypoints` turning `rasterScanlines`' rows into an actual rapid/
    /// plunge/retract pass.
    private func facingScanlines(within contour: SC.Contour,
                                 extensionLength: Double,
                                 tool: SC.ToolParams,
                                 direction: SC.CutDirection) -> [[SC.Segment]] {

        let stepover = facingStepover(for: tool)
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
