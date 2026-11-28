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
    ///
    /// `closeGaps` (default `true`) applies to `.contour`, whatever the side, and to `.pocket`: before
    /// anything is calculated, a contour made of entities that don't form one continuous outline is
    /// repaired. The entities are put in order and orientation, each break is bridged to the closest
    /// next point, and the outline is closed back onto its start (see `closingGaps(in:)`). For a
    /// pocket this also joins the open contours that make up one outline (lines at different Z
    /// heights that only meet once projected), after the open outlines ending on a wall are closed
    /// against it.
    public func generateToolpaths(from contours: [SC.Contour],
                                  tool: SC.ToolParams,
                                  settings: SC.MachineSettings,
                                  operation: SC.MachiningOperation,
                                  closeGaps: Bool = true) throws -> [SC.OutputToolpath] {

        guard settings.allowance.isFinite, settings.allowance >= 0 else {
            throw SC.Error.invalidParameter("allowance")
        }

        var results: [SC.OutputToolpath] = []

        // Pockets leave islands standing: any closed shape nested inside another becomes
        // an island of it (and a shape inside an island is a pocket again), so the caller
        // can pass one flat list of shapes.
        var contours = contours
        // Pass `closeGaps: false` to cut an open path as it is.
        if case .contour = operation, closeGaps {
            contours = closingGaps(in: contours)
        }
        if case .pocket = operation {
            // An open outline with both ends on a wall is an island sharing the wall; islands
            // touching the wall are cut out of it, so what's left is plain pockets and islands.
            contours = closingOpenContours(contours)
            // What is still open after that is an outline split over several contours (lines
            // drawn at different Z heights only touch once projected to Z0): chain the pieces
            // back together and close them, the same way a contour is repaired. This runs
            // after `closingOpenContours` so an outline that ends on a wall is closed against
            // the wall, not with a straight bridge.
            if closeGaps {
                contours = closingGaps(in: contours)
            }
            contours = resolvePocketIslands(contours)
            contours = mergingTouchingIslands(contours)
        }
        // A 3D pocket detects its islands the same way, but does not merge the ones touching the
        // wall here: whether such an island is part of the wall depends on the layer, so each
        // band of layers does it for its own standing islands (see `buildPocket3DToolpath`).
        if case .pocket3D = operation {
            contours = closingOpenContours(contours)
            let resolved = resolvePocketIslandsReportingDepth(contours)
            // A shape inside an island would be a pocket again for the 2D engine, but its
            // height is not defined.
            guard resolved.maxDepth < 2 else {
                throw SC.Error.invalidParameter("nested islands are not supported")
            }
            contours = resolved.contours
        }

        // Facing clears one area for the whole selection: every selected shape folds into a
        // single rectangle (the union of their bounding boxes), so it yields one toolpath
        // rather than one per shape.
        if case .facing = operation, let combined = facingBoundingContour(of: contours) {
            contours = [combined]
        }

        // A shape the tool is too big for (a small hole with a large bit) is left out, with a
        // warning, instead of failing the whole job or cutting something that isn't there. Only
        // when every shape is left out is there nothing to return, and that stays an error.
        var skipped: [SC.Warning] = []
        var lastCollapse: SC.Error?
        for contour in contours {
            do {
                if let toolpath = try buildToolpath(for: contour, tool: tool, settings: settings, operation: operation) {
                    results.append(applyEntryDescent(to: applyEntryHeight(to: toolpath)))
                }
            } catch SC.Error.geometryCollapsed {
                lastCollapse = .geometryCollapsed
                skipped.append(.toolDoesNotFit(shapeSize: Self.narrowestSpan(of: contour), toolDiameter: tool.diameter))
            }
        }

        if results.isEmpty, let lastCollapse {
            throw lastCollapse
        }
        if !skipped.isEmpty {
            results[0].warnings.append(contentsOf: skipped)
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

            case .pocket3D(let direction, let pattern, let entry):
                try buildPocket3DToolpath(for: contour,
                                          tool: tool,
                                          settings: settings,
                                          direction: direction,
                                          pattern: pattern,
                                          entry: entry,
                                          operation: operation)

            case .facing(let direction, let extensionLength, let angle):
                try buildFacingToolpath(for: contour,
                                        tool: tool,
                                        settings: settings,
                                        direction: direction,
                                        extensionLength: extensionLength,
                                        angle: angle,
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

    /// The smaller side of the contour's bounding box: how tight the shape is, for a message.
    static func narrowestSpan(of contour: SC.Contour) -> Double {
        let points = contour.linearizedSegments.flatMap { [$0.startPoint, $0.endPoint] }
        guard let first = points.first else {
            return 0
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return Double(min(maxX - minX, maxY - minY))
    }
}
