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

            case .contour(let side, let direction, let entry, let leadIn, let leadOut, let tabs):
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
                // `.facing` clears a `Stock`'s whole top-face footprint, not this
                // per-contour `contour` -- there's nothing here for it to act on.
                // Use `generateToolpaths(from operations: [SC.FacingOperation])`
                // instead (Step 2A.2), which builds the real toolpath via
                // `buildFacingToolpath`.
                return nil

            case .slotting(depthPerPass: let depthPerPass, entry: let entry):
                print("depthPerPass \(depthPerPass), entry \(entry)")
                return nil

            case .tapping(pitch: let pitch, isInternal: let isInternal, direction: let direction):
                print("pitcher \(pitch), internal \(isInternal), direction \(direction)")
                return nil

            case .boring(targetDiameter: let targetDiameter, dwellTime: let dwellTime, shiftRetract: let shiftRetract):
                print("targetDiameter \(targetDiameter), dwellTime \(String(describing: dwellTime)), shiftRetract \(shiftRetract)")
                return nil
        }
    }

    // MARK: - Internal Helper Steps

    public func linearize(contour: SC.Contour) -> [SC.Segment] {
        var segments: [SC.Segment] = []

        for chained in contour.entities {
            let extracted = convert(entity: chained.entity, reversed: chained.reversed)
            segments.append(contentsOf: extracted)
        }

        return segments
    }

    /// Converts a raw DXF entity into normalized CNC path primitives (`Segment`).
    /// - Parameters:
    ///   - entity: The source DXF entity from the contour chain.
    ///   - reversed: `true` if EntityChainer is walking the entity backwards.
    /// - Returns: An array of linear and circular arc segments representing the cutter motion.
    public func convert(entity: DXF.Entity, reversed: Bool) -> [SC.Segment] {

        switch entity {
            case let .line(a, b, _, _):
                let start = reversed ? b.cgPoint : a.cgPoint
                let end = reversed ? a.cgPoint : b.cgPoint
                return [.line(start: start, end: end)]

            case let .circle(center, radius, _, _):
                let centerPt = center.cgPoint
                // DXF circles map to 2x 180° arcs to ensure compatibility with standard CNC controllers
                if reversed {
                    return [
                        .arc(center: centerPt, radius: radius, startAngle: .pi, endAngle: 0, isCCW: false),
                        .arc(center: centerPt, radius: radius, startAngle: 2 * .pi, endAngle: .pi, isCCW: false)
                    ]
                } else {
                    return [
                        .arc(center: centerPt, radius: radius, startAngle: 0, endAngle: .pi, isCCW: true),
                        .arc(center: centerPt, radius: radius, startAngle: .pi, endAngle: 2 * .pi, isCCW: true)
                    ]
                }

            case let .arc(center, radius, startDeg, endDeg, _, _):
                let start = startDeg * .pi / 180.0
                var end = endDeg * .pi / 180.0

                // DXF arcs sweep CCW start -> end. Normalize end angle.
                while end < start {
                    end += 2 * .pi
                }

                let centerPt = center.cgPoint
                if reversed {
                    // Same physical arc, swept backwards (CW)
                    return [.arc(center: centerPt, radius: radius, startAngle: end, endAngle: start, isCCW: false)]
                } else {
                    return [.arc(center: centerPt, radius: radius, startAngle: start, endAngle: end, isCCW: true)]
                }

            case let .polyline(vertices, closed, _, _):
                let ordered = reversed ? reversedPolylineVertices(vertices, closed: closed) : vertices
                return segmentsFromPolyline(vertices: ordered, closed: closed)

            case let .ellipse(center, majorAxis, ratio, startParam, endParam, _, _):
                // Tessellate ellipse into tiny linear segments (G1 moves)
                return segmentsFromEllipse(
                    center: center.cgPoint,
                    majorAxis: majorAxis.cgPoint,
                    ratio: ratio,
                    startParam: startParam,
                    endParam: endParam,
                    reversed: reversed
                )

            case .point, .text, .dimension:
                // Non-machinable primitives generate no physical toolpath moves
                return []
        }
    }

    // MARK: - Polyline Helpers

    private func segmentsFromPolyline(vertices: [DXF.PolyVertex], closed: Bool) -> [SC.Segment] {
        guard vertices.count >= 2 else { return [] }
        var segments: [SC.Segment] = []

        let segmentCount = closed ? vertices.count : (vertices.count - 1)
        for i in 0..<segmentCount {
            let current = vertices[i]
            let next = vertices[(i + 1) % vertices.count]

            let startPt = current.point.cgPoint
            let endPt = next.point.cgPoint

            if abs(current.bulge) < 1e-12 {
                segments.append(.line(start: startPt, end: endPt))
            } else if let bulgeArc = createBulgeArc(from: startPt, to: endPt, bulge: current.bulge) {
                segments.append(bulgeArc)
            }
        }

        return segments
    }

    /// Converts a polyline bulge value into a CCW/CW arc segment.
    private func createBulgeArc(from a: CGPoint, to b: CGPoint, bulge: Double) -> SC.Segment? {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let chord = hypot(dx, dy)

        guard chord > 1e-12 else { return nil }

        let theta = 4.0 * atan(bulge)
        let halfChord = chord / 2.0
        let radius = halfChord / abs(sin(theta / 2.0))

        let mx = (a.x + b.x) / 2.0
        let my = (a.y + b.y) / 2.0

        // Unit perpendicular vector
        let nx = -dy / chord
        let ny = dx / chord

        let centerDistance = halfChord / tan(abs(theta) / 2.0)
        let sign = bulge >= 0 ? 1.0 : -1.0

        let center = CGPoint(
            x: mx + nx * centerDistance * sign,
            y: my + ny * centerDistance * sign
        )

        let startAngle = atan2(a.y - center.y, a.x - center.x)
        let endAngle = atan2(b.y - center.y, b.x - center.x)
        let isCCW = bulge > 0

        return .arc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            isCCW: isCCW
        )
    }

    /// Reverses polyline vertex order and flips bulge signs for backward walking.
    private func reversedPolylineVertices(_ vertices: [DXF.PolyVertex], closed: Bool) -> [DXF.PolyVertex] {

        let n = vertices.count
        guard n > 1 else {
            return vertices
        }

        return (0..<n).map { i in
            let originalIndex = n - 1 - i
            let bulgeSourceIndex = originalIndex - 1
            let bulge: Double

            if bulgeSourceIndex >= 0 {
                bulge = -vertices[bulgeSourceIndex].bulge
            } else if closed {
                bulge = -vertices[n - 1].bulge
            } else {
                bulge = 0
            }

            return DXF.PolyVertex(vertices[originalIndex].point, bulge: bulge)
        }
    }

    // MARK: - Ellipse Helpers

    private func segmentsFromEllipse(center: CGPoint,
                                     majorAxis: CGPoint,
                                     ratio: Double,
                                     startParam: Double,
                                     endParam: Double,
                                     reversed: Bool) -> [SC.Segment] {

        let majorRadius = hypot(majorAxis.x, majorAxis.y)
        let minorRadius = majorRadius * ratio
        let rotation = atan2(majorAxis.y, majorAxis.x)

        let sampleCount = max(32, Int(abs(endParam - startParam) * 32 / (2 * .pi)))
        var points: [CGPoint] = []

        for i in 0...sampleCount {
            let t = startParam + (endParam - startParam) * Double(i) / Double(sampleCount)

            let x = majorRadius * cos(t)
            let y = minorRadius * sin(t)

            let xr = x * cos(rotation) - y * sin(rotation)
            let yr = x * sin(rotation) + y * cos(rotation)

            points.append(CGPoint(x: center.x + xr, y: center.y + yr))
        }

        if reversed {
            points.reverse()
        }

        var segments: [SC.Segment] = []
        for i in 0..<(points.count - 1) {
            segments.append(.line(start: points[i], end: points[i + 1]))
        }
        return segments
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
