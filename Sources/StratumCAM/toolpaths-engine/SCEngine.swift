//
//  CAMEngine.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 10.09.2026.
//

import Foundation
import simd

public final class SCEngine {

    public init() {}

    /// Generates toolpaths for the given strategy. Each contour becomes zero or one
    /// `OutputToolpath` depending on whether the strategy has anything machinable to say
    /// about it (e.g. `.drilling` on a non-closed contour currently yields nothing).
    ///
    /// `strategy` defaults to `.engrave`, which traces the geometry exactly at cutter-center
    /// (no tool-radius compensation) -- the classic engraving / center-line cutting case.
    ///
    public func generateToolpaths(from contours: [SC.Contour],
                                  tool: SC.ToolParams,
                                  settings: SC.MachineSettings,
                                  operation: SC.MachiningOperation) throws -> [SC.OutputToolpath] {

        guard settings.allowance.isFinite, settings.allowance >= 0 else {
            throw SC.Error.invalidParameter("allowance")
        }

        var results: [SC.OutputToolpath] = []

        // Pockets leave islands standing: any closed shape nested inside another becomes
        // an island of it (and a shape inside an island is a pocket again), so the caller
        // can pass one flat list of shapes.
        var contours = contours
        if case .pocket = operation {
            // An open outline with both ends on a wall is an island sharing the wall; islands
            // touching the wall are cut out of it, so what's left is plain pockets and islands.
            contours = closingOpenContours(contours)
            contours = resolvePocketIslands(contours)
            contours = mergingTouchingIslands(contours)
        }

        for contour in contours {
            if let toolpath = try buildToolpath(for: contour, tool: tool, settings: settings, operation: operation) {
                results.append(applyEntryHeight(to: toolpath))
            }
        }

        return results
    }

    // MARK: - Strategy dispatch

    private func buildToolpath(for contour: SC.Contour,
                               tool: SC.ToolParams,
                               settings: SC.MachineSettings,
                               operation: SC.MachiningOperation) throws -> SC.OutputToolpath? {
        // Stock to leave only applies to the operations that say so (see
        // `OperationRequirements.usesAllowance`); the rest cut straight to size.
        if settings.allowance > 1e-9, operation.requirements.usesAllowance {
            return try buildToolpathLeavingStock(for: contour, tool: tool, settings: settings, operation: operation)
        }
        return try buildPlainToolpath(for: contour, tool: tool, settings: settings, operation: operation)
    }

    /// One operation on one contour, cut straight to the finished size (no stock left).
    /// `buildToolpathLeavingStock` builds on it.
    func buildPlainToolpath(for contour: SC.Contour,
                            tool: SC.ToolParams,
                            settings: SC.MachineSettings,
                            operation: SC.MachiningOperation) throws -> SC.OutputToolpath? {
        switch operation {
            case .engrave(let entry):
                try buildContourTracingToolpath(for: contour,
                                                tool: tool,
                                                settings: settings,
                                                side: .onContour,
                                                entry: entry,
                                                operation: operation)

            case .contour(let side, let direction, let entry, let leadIn, let leadOut, let tabs):
                try buildContourToolpath(for: contour,
                                         tool: tool,
                                         settings: settings,
                                         side: side,
                                         direction: direction,
                                         entry: entry,
                                         leadIn: leadIn,
                                         leadOut: leadOut,
                                         tabs: tabs,
                                         operation: operation)

            case .chamfer(let params):
                try buildChamferToolpath(for: contour,
                                         tool: tool,
                                         settings: settings,
                                         params: params,
                                         operation: operation)

            case .drilling(let peckDepth):
                try buildDrillingToolpath(for: contour,
                                          tool: tool,
                                          settings: settings,
                                          peckDepth: peckDepth,
                                          operation: operation)

            case .pocket(let direction, let pattern, let entry):
                try buildPocketToolpath(for: contour,
                                        tool: tool,
                                        settings: settings,
                                        direction: direction,
                                        pattern: pattern,
                                        entry: entry,
                                        operation: operation
                )

            case .facing(let direction, let extensionLength):
                try buildFacingToolpath(for: contour,
                                        tool: tool,
                                        settings: settings,
                                        direction: direction,
                                        extensionLength: extensionLength,
                                        operation: operation)

            case .slotting(let depthPerPass, let pattern, let entry):
                try buildSlottingToolpath(for: contour,
                                          tool: tool,
                                          settings: settings,
                                          pattern: pattern,
                                          depthPerPass: depthPerPass,
                                          entry: entry,
                                          operation: operation)

            case .threadMilling(pitch: let pitch,
                                isInternal: let isInternal,
                                direction: let direction,
                                radialPasses: let radialPasses,
                                targetDiameter: let targetDiameter):
                try buildThreadMillingToolpath(for: contour,
                                               tool: tool,
                                               settings: settings,
                                               pitch: pitch,
                                               isInternal: isInternal,
                                               direction: direction,
                                               radialPasses: radialPasses,
                                               targetDiameter: targetDiameter,
                                               operation: operation)

            case .boring(targetDiameter: let targetDiameter, dwellTime: _, shiftRetract: let shiftRetract):
                // dwellTime doesn't touch the waypoints -- it's a G-code-only concern
                // handled by SCGCodeEngine reading it straight off `operation` (Step 2C.2).
                try buildBoringToolpath(for: contour,
                                        tool: tool,
                                        settings: settings,
                                        targetDiameter: targetDiameter,
                                        shiftRetract: shiftRetract,
                                        operation: operation)

            case .counterbore(let diameter, let depth, let direction, let entry):
                try buildCounterboreToolpath(for: contour,
                                             tool: tool,
                                             settings: settings,
                                             diameter: diameter,
                                             depth: depth,
                                             direction: direction,
                                             entry: entry,
                                             operation: operation)
        }
    }

    public func buildWaypoints(for segments: [SC.Segment], atZ z: Double, settings: SC.MachineSettings) -> [SC.Waypoint] {
        var waypoints: [SC.Waypoint] = []

        guard let first = segments.first else {
            return []
        }
        let startPoint = first.startPoint

        // TODO: should the plunge be moved to buildEntryWaypoints?

        // 1. Rapid move above start point at Safe Z
        waypoints.append(SC.Waypoint(position: SIMD3(startPoint.x, startPoint.y, settings.safeZ),
                                     motion: .rapid,
                                     feedRate: settings.cutting.feedRate))

        // TODO: should be an intermediate step with retractZ?

        // 2. Plunge down to target Z
        waypoints.append(SC.Waypoint(position: SIMD3(startPoint.x, startPoint.y, z),
                                     motion: .linear,
                                     feedRate: settings.cutting.plungeRate))

        // 3. Trace segments along XY plane
        for segment in segments {
            switch segment {
                case .line(_, let end):
                    waypoints.append(SC.Waypoint(position: SIMD3(end.x, end.y, z),
                                                 motion: .linear,
                                                 feedRate: settings.cutting.feedRate))

                case .arc(let center, let radius, _, let endAngle, let isCCW):
                    // Compute end position using radius and radian end angle
                    let endX = center.x + radius * cos(endAngle)
                    let endY = center.y + radius * sin(endAngle)
                    let motion: SC.MotionType = isCCW ? .arcCCW(center: center) : .arcCW(center: center)

                    waypoints.append(SC.Waypoint(position: SIMD3(endX, endY, z),
                                                 motion: motion,
                                                 feedRate: settings.cutting.feedRate))
            }
        }

        // 4. Retract back to Safe Z after contour completion
        if let lastPoint = waypoints.last?.position {
            waypoints.append(SC.Waypoint(position: SIMD3(lastPoint.x, lastPoint.y, settings.safeZ),
                                         motion: .rapid,
                                         feedRate: settings.cutting.feedRate))
        }

        return waypoints
    }
}
