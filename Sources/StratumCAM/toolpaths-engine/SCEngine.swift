//
//  CAMEngine.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 10.09.2026.
//

import Foundation
import simd
import SwiftDXF

public final class SCEngine {

    public init() {}

    /// Generates toolpaths for the given strategy. Each contour becomes zero or one
    /// `OutputToolpath` depending on whether the strategy has anything machinable to say
    /// about it (e.g. `.drilling` on a non-point contour currently yields nothing).
    ///
    /// `strategy` defaults to `.engrave`, which traces the geometry exactly at cutter-center
    /// (no tool-radius compensation) -- the classic engraving / center-line cutting case.
    public func generateToolpaths(from contours: [SC.Contour],
                                  tool: SC.ToolParams,
                                  settings: SC.MachineSettings,
                                  operation: SC.MachiningOperation) -> [SC.OutputToolpath] {

        var results: [SC.OutputToolpath] = []

        for contour in contours {
            if let toolpath = buildToolpath(for: contour, tool: tool, settings: settings, operation: operation) {
                results.append(toolpath)
            }
        }

        return results
    }

    /// Generates a batch of drilling toolpaths where each hole may use its own
    /// drill tool, machine settings, and peck strategy. This is intentionally a
    /// drilling-specific overload so the existing single-tool API remains stable
    /// for engraving, profiling, chamfering, and future strategies.
    public func generateToolpaths(from operations: [SC.DrillingOperation]) -> [SC.OutputToolpath] {
        operations.compactMap { operation in
            buildToolpath(
                for: operation.contour,
                tool: operation.tool,
                settings: operation.settings,
                operation: .drilling(peckDepth: operation.peckDepth)
            )
        }
    }

    /// Generates facing toolpaths, one per `FacingOperation`. `.facing` has no
    /// selected contour to iterate -- it clears a `Stock`'s whole top-face footprint
    /// once -- so it can't go through the per-contour `buildToolpath` switch below
    /// the way every other strategy does (see `FacingOperation`'s doc comment and
    /// Step 2A.1's flag on this exact gap). This is a dedicated overload for that,
    /// mirroring the `DrillingOperation` overload above's solution to the same kind
    /// of signature mismatch.
    public func generateToolpaths(from operations: [SC.FacingOperation]) -> [SC.OutputToolpath] {
        operations.compactMap { operation in
            buildFacingToolpath(
                stock: operation.stock,
                tool: operation.tool,
                settings: operation.settings,
                stepover: operation.stepover,
                direction: operation.direction,
                extensionLength: operation.extensionLength,
                operation: .facing(stepover: operation.stepover,
                                   direction: operation.direction,
                                   extensionLength: operation.extensionLength)
            )
        }
    }

    // MARK: - Strategy dispatch

    /// Routes a single contour to the builder for its strategy. Returns `nil` when the
    /// contour has nothing machinable (e.g. an empty/degenerate contour) or -- for now --
    /// when the strategy's real geometry isn't implemented yet (see TODOs below).
    private func buildToolpath(for contour: SC.Contour,
                               tool: SC.ToolParams,
                               settings: SC.MachineSettings,
                               operation: SC.MachiningOperation) -> SC.OutputToolpath? {
        switch operation {
            case .engrave:
                return buildContourTracingToolpath(for: contour,
                                                   tool: tool,
                                                   settings: settings,
                                                   side: .onContour,
                                                   operation: operation)

            case .profile(let side, let direction, let entry, let leadIn, let leadOut, let tabs):
                return buildContourToolpath(for: contour,
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
                return buildChamferToolpath(for: contour,
                                            tool: tool,
                                            settings: settings,
                                            params: params,
                                            operation: operation)

            case .drilling(let peckDepth):
                return buildDrillingToolpath(for: contour,
                                             tool: tool,
                                             settings: settings,
                                             peckDepth: peckDepth,
                                             operation: operation)

            case .pocket(let direction, let pattern, let entry):
                return buildPocketToolpath(for: contour,
                                           tool: tool,
                                           settings: settings,
                                           direction: direction,
                                           pattern: pattern,
                                           entry: entry,
                                           operation: operation
                )

            case .facing:
                print("Use `generateToolpaths(from operations: [SC.FacingOperation])` instead.")
                return nil

            case .slotting(let depthPerPass, let pattern, let entry):
                return buildSlottingToolpath(for: contour,
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

                return buildThreadMillingToolpath(for: contour,
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
                return buildBoringToolpath(for: contour,
                                           tool: tool,
                                           settings: settings,
                                           targetDiameter: targetDiameter,
                                           shiftRetract: shiftRetract,
                                           operation: operation)
        }
    }

    /// Gives a list of passes
    func calculateZPasses(targetDepth: Double, stepdown: Double) -> [Double] {
        let absoluteTarget = abs(targetDepth)
        let step = abs(stepdown)
        guard step > 0, absoluteTarget > 0 else {
            return [-absoluteTarget]
        }

        // Number of full-depth passes needed. Dividing doubles can land a hair on either
        // side of a whole number (e.g. 1.0 / 0.1 == 9.999999999999998), so snap to the
        // nearest integer when we're within a tiny tolerance of one before rounding up --
        // otherwise a perfectly even depth/stepdown pair would silently gain an extra
        // pass. Once the count is fixed, each depth is derived by multiplication rather
        // than repeated addition, so there's no accumulated drift across passes either.
        let rawCount = absoluteTarget / step
        let epsilon = 1e-9
        let passCount: Int
        if abs(rawCount.rounded() - rawCount) < epsilon {
            passCount = max(1, Int(rawCount.rounded()))
        } else {
            passCount = max(1, Int(rawCount.rounded(.up)))
        }

        return (0..<passCount).map { i in
            let depth = (i == passCount - 1) ? absoluteTarget : step * Double(i + 1)
            return -depth
        }
    }

    public func buildWaypoints(for segments: [SC.Segment], atZ z: Double, settings: SC.MachineSettings) -> [SC.Waypoint] {
        var waypoints: [SC.Waypoint] = []

        guard let first = segments.first else {
            return []
        }
        let startPoint = startPointOf(segment: first)

        // 1. Rapid move above start point at Safe Z
        waypoints.append(SC.Waypoint(position: SIMD3(startPoint.x, startPoint.y, settings.safeZ),
                                     motion: .rapid,
                                     feedRate: settings.cutting.feedRate))

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

    func startPointOf(segment: SC.Segment) -> CGPoint {
        switch segment {
        case .line(let start, _):
            return start
        case .arc(let center, let radius, let startAngle, _, _):
            return CGPoint(x: center.x + radius * cos(startAngle), y: center.y + radius * sin(startAngle))
        }
    }
}

extension DXF.Point {
    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}
