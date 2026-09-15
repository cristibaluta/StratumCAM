//
//  SCEngine+Contour.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import SwiftDXF

extension SCEngine {

    /// Shared pipeline behind `.engrave` and (for now) `.contour`: linearize the contour,
    /// optionally apply tool-radius compensation, step down through Z, and trace the
    /// resulting segments once per pass. The `strategy` passed in is the one actually
    /// requested by the caller, so the output is tagged accurately instead of hardcoded.
    ///
    /// Throws `SC.Error.invalidContour` (Step 6.4, same pattern established in 6.2/6.3)
    /// rather than returning `nil` when the contour linearizes to zero segments. This
    /// function backs both `.engrave` and `.profile` in `buildToolpath`'s dispatch switch,
    /// so both operations start throwing on empty geometry as of this step, not just
    /// `.profile` -- they share this one pipeline rather than each having their own copy.
    func buildContourTracingToolpath(for contour: SC.Contour,
                                     tool: SC.ToolParams,
                                     settings: SC.MachineSettings,
                                     side: SC.CutSide,
                                     operation: SC.MachiningOperation) throws -> SC.OutputToolpath {

        // 1. Normalize DXF Entities into linear/arc segments (handling reversed flag)
        let baseSegments = contour.linearizedSegments
        guard !baseSegments.isEmpty else {
            throw SC.Error.invalidContour
        }

        // 1b. Apply tool-radius compensation for inside/outside profile cuts
        let toolpathSegments = offsetContour(baseSegments,
                                             side: side,
                                             toolRadius: tool.diameter / 2.0,
                                             isClosed: contour.isClosed)

        // 2. Calculate Z depth passes based on the configured cutting stepdown
        let zDepths = EngineTools.calculateZPasses(targetDepth: settings.targetDepth, stepdown: settings.cutting.stepdown)

        // 3. Build waypoints per pass
        var passes: [SC.ToolpathPass] = []
        for (i, z) in zDepths.enumerated() {
            let waypoints = buildWaypoints(for: toolpathSegments, atZ: z, settings: settings)
            passes.append(SC.ToolpathPass(passIndex: i, depthZ: z, waypoints: waypoints))
        }

        return SC.OutputToolpath(operation: operation, tool: tool, settings: settings, passes: passes)
    }

    /// Builds a toolpath for `.contour`, honoring `direction`, `entry`, `leadIn`/`leadOut`,
    /// and `tabs` -- unlike `.engrave`, which just traces the geometry at cutter-center with
    /// a plain vertical plunge.
    ///
    /// Throws (Step 6.4, same pattern established in 6.2/6.3) at its two failure sites:
    /// `SC.Error.invalidContour` when the contour linearizes to zero segments -- the input
    /// itself has nothing to build from -- and `SC.Error.geometryCollapsed` when offsetting
    /// an otherwise-valid contour leaves nothing behind (e.g. a tool radius wide enough to
    /// consume the whole shape). Distinct cases because the second one only shows up after
    /// `baseSegments` already passed validation; the algorithm, not the input, is what
    /// produced nothing.
    func buildContourToolpath(for contour: SC.Contour,
                              tool: SC.ToolParams,
                              settings: SC.MachineSettings,
                              side: SC.CutSide,
                              direction cutDirection: SC.CutDirection,
                              entry: SC.EntryStrategy,
                              leadIn: SC.LeadInOut?,
                              leadOut: SC.LeadInOut?,
                              tabs: [SC.HoldingTab],
                              operation: SC.MachiningOperation) throws -> SC.OutputToolpath {

        let baseSegments = contour.linearizedSegments
        guard !baseSegments.isEmpty else {
            throw SC.Error.invalidContour
        }

        // 1. Orient the chain so travel direction matches the requested climb/conventional cut.
        let oriented = orientedForDirection(baseSegments, side: side, direction: cutDirection)

        // 2. Tool-radius compensation (existing offset engine).
        let toolpathSegments = offsetContour(oriented, side: side, toolRadius: tool.diameter / 2.0, isClosed: contour.isClosed)
        guard let firstSegment = toolpathSegments.first else {
            throw SC.Error.geometryCollapsed
        }

        let zDepths = EngineTools.calculateZPasses(targetDepth: settings.targetDepth, stepdown: settings.cutting.stepdown)
        let totalDepth = abs(settings.targetDepth)

        var passes: [SC.ToolpathPass] = []
        var previousZ = 0.0 // top of stock -- pass 0 ramps/helixes down from here, not from safeZ.
        for (i, z) in zDepths.enumerated() {
            let waypoints = buildProfileWaypoints(
                for: toolpathSegments,
                firstSegment: firstSegment,
                atZ: z,
                previousZ: previousZ,
                totalDepth: totalDepth,
                side: side,
                settings: settings,
                entry: entry,
                leadIn: leadIn,
                leadOut: leadOut,
                tabs: tabs
            )
            passes.append(SC.ToolpathPass(passIndex: i, depthZ: z, waypoints: waypoints))
            previousZ = z
        }

        return SC.OutputToolpath(operation: operation, tool: tool, settings: settings, passes: passes)
    }

    // MARK: - Direction

    /// Reorders/reverses the segment chain so it travels the way `direction` requires for
    /// this `side`. Assumes a standard clockwise-rotating spindle (the common case for CNC
    /// routers/mills): climb milling an `.outside` profile requires travelling CCW around
    /// the part; climb milling an `.inside` wall (e.g. a pocket boundary) requires
    /// travelling CW. `.onContour` has no material on one side by definition, so it follows
    /// the same convention as `.outside` for consistency.
    func orientedForDirection(_ segments: [SC.Segment], side: SC.CutSide, direction: SC.CutDirection) -> [SC.Segment] {
        let wantsCCW: Bool
        switch side {
            case .outside, .onContour:
                wantsCCW = direction == .climb
            case .inside:
                wantsCCW = direction == .conventional
        }

        guard OffsetTools.isCCWWinding(segments) != wantsCCW else {
            return segments
        }
        return segments.reversed().map { $0.reversed }
    }

    // MARK: - Waypoint assembly

    private func buildProfileWaypoints(for segments: [SC.Segment],
                                       firstSegment: SC.Segment,
                                       atZ z: Double,
                                       previousZ: Double,
                                       totalDepth: Double,
                                       side: SC.CutSide,
                                       settings: SC.MachineSettings,
                                       entry: SC.EntryStrategy,
                                       leadIn: SC.LeadInOut?,
                                       leadOut: SC.LeadInOut?,
                                       tabs: [SC.HoldingTab]) -> [SC.Waypoint] {

        let contourStart = firstSegment.startPoint
        let startTangent = direction(of: firstSegment, atEnd: false)

        var waypoints: [SC.Waypoint] = []

        switch entry {
            case .plunge:
                let (entryPoint, leadInMove) = resolveLeadIn(leadIn,
                                                             side: side,
                                                             contourStart: contourStart,
                                                             tangent: startTangent,
                                                             segments: segments,
                                                             z: z)
                waypoints.append(
                    SC.Waypoint(position: SIMD3(entryPoint.x, entryPoint.y, settings.safeZ),
                                motion: .rapid,
                                feedRate: settings.cutting.feedRate)
                )
                waypoints.append(
                    SC.Waypoint(position: SIMD3(entryPoint.x, entryPoint.y, z),
                                motion: .linear,
                                feedRate: settings.cutting.plungeRate)
                )
                if let leadInMove {
                    waypoints.append(leadInMove)
                }

            case .ramp(let angleDegrees):
                // Travel at safeZ, but the ramp itself only needs to cover this pass's
                // fresh stepdown -- it starts at the depth the previous pass already
                // reached (0 / top-of-stock for the first pass), not safeZ. Ramping the
                // full safeZ->z distance on every pass would re-descend through material
                // that's already open air from earlier passes.
                waypoints.append(
                    SC.Waypoint(position: SIMD3(contourStart.x, contourStart.y, settings.safeZ),
                                motion: .rapid,
                                feedRate: settings.cutting.feedRate)
                )
                waypoints.append(
                    SC.Waypoint(position: SIMD3(contourStart.x, contourStart.y, previousZ),
                                motion: .rapid,
                                feedRate: settings.cutting.feedRate)
                )
                waypoints.append(
                    contentsOf: RampTools.rampWaypoints(firstSegment: firstSegment,
                                                        angleDegrees: angleDegrees,
                                                        fromZ: previousZ,
                                                        toZ: z,
                                                        settings: settings)
                )

            case .helix(let radius, let angleDegrees):
                // Same reasoning as `.ramp` above: travel at safeZ, but helix down only
                // from the previous pass's depth to this pass's depth.
                waypoints.append(
                    SC.Waypoint(position: SIMD3(contourStart.x, contourStart.y, settings.safeZ),
                                motion: .rapid,
                                feedRate: settings.cutting.feedRate)
                )
                waypoints.append(
                    SC.Waypoint(position: SIMD3(contourStart.x, contourStart.y, previousZ),
                                motion: .rapid,
                                feedRate: settings.cutting.feedRate)
                )
                waypoints.append(
                    contentsOf: RampTools.helixEntryWaypoints(contourStart: contourStart,
                                                              startTangent: startTangent,
                                                              side: side,
                                                              segments: segments,
                                                              firstSegment: firstSegment,
                                                              radius: radius,
                                                              angleDegrees: angleDegrees,
                                                              fromZ: previousZ,
                                                              toZ: z,
                                                              settings: settings)
                )

            case .fromOpenEnd(stepoverPercentage: _):
                break
        }

        // Trace the contour itself, clamping Z at any holding tabs.
        waypoints.append(
            contentsOf: tracedWaypoints(for: segments,
                                        atZ: z,
                                        totalDepth: totalDepth,
                                        tabs: tabs,
                                        settings: settings)
        )

        // Lead-out + retract.
        guard let lastSegment = segments.last else {
            return waypoints
        }
        let contourEnd = lastSegment.endPoint

        if entry == .plunge {
            let endTangent = direction(of: lastSegment, atEnd: true)
            if let (exitPoint, leadOutMove) = resolveLeadOut(leadOut,
                                                             side: side,
                                                             contourEnd: contourEnd,
                                                             tangent: endTangent,
                                                             segments: segments,
                                                             z: z) {
                waypoints.append(leadOutMove)
                waypoints.append(
                    SC.Waypoint(position: SIMD3(exitPoint.x, exitPoint.y, settings.safeZ),
                                motion: .rapid,
                                feedRate: settings.cutting.feedRate)
                )
                return waypoints
            }
        }

        waypoints.append(
            SC.Waypoint(position: SIMD3(contourEnd.x, contourEnd.y, settings.safeZ),
                        motion: .rapid,
                        feedRate: settings.cutting.feedRate)
        )
        return waypoints
    }

    // MARK: - Lead-in / lead-out (plunge entry only, see file header)

    /// Resolves where a `.plunge` entry should actually land, and the extra waypoint that
    /// carries the tool from there onto `contourStart`, for a given `LeadInOut` style.
    ///
    /// Not converted to `throws` in Step 6.4: `leadIn == nil` means "no lead-in configured,"
    /// a legitimate, common choice, not a broken input -- entering straight at `contourStart`
    /// is `buildProfileWaypoints`' own valid fallback, not an error state for the caller to
    /// catch.
    private func resolveLeadIn(_ leadIn: SC.LeadInOut?,
                               side: SC.CutSide,
                               contourStart: CGPoint,
                               tangent: CGPoint,
                               segments: [SC.Segment],
                               z: Double) -> (entryPoint: CGPoint, move: SC.Waypoint?) {

        guard let leadIn else {
            return (contourStart, nil)
        }

        switch leadIn.style {
            case .linear(let length):
                let entryPoint = CGPoint(x: contourStart.x - tangent.x * length, y: contourStart.y - tangent.y * length)
                let move = SC.Waypoint(position: SIMD3(contourStart.x, contourStart.y, z), motion: .linear, feedRate: leadIn.feedRate)
                return (entryPoint, move)

            case .arc(let radius, let sweepDegrees):
                let signedOffset = OffsetTools.offsetDistance(for: side, toolRadius: radius, segments: segments)
                let normal = CGPoint(x: -tangent.y, y: tangent.x)
                let center = CGPoint(x: contourStart.x + normal.x * signedOffset, y: contourStart.y + normal.y * signedOffset)
                let isCCW = signedOffset > 0
                let contourAngle = atan2(contourStart.y - center.y, contourStart.x - center.x)
                let sweepRad = sweepDegrees.degreesToRadians
                // Walk backwards from the contour point to find where the lead-in arc starts.
                let entryAngle = isCCW ? contourAngle - sweepRad : contourAngle + sweepRad
                let entryPoint = CGPoint(x: center.x + radius * cos(entryAngle), y: center.y + radius * sin(entryAngle))
                let move = SC.Waypoint(position: SIMD3(contourStart.x, contourStart.y, z),
                                       motion: isCCW ? .arcCCW(center: center) : .arcCW(center: center),
                                       feedRate: leadIn.feedRate)
                return (entryPoint, move)
        }
    }

    /// Mirror of `resolveLeadIn` for the departure end of the cut. Same reasoning applies:
    /// not converted to `throws` -- `leadOut == nil` is "no lead-out configured," not an error.
    private func resolveLeadOut(_ leadOut: SC.LeadInOut?,
                                side: SC.CutSide,
                                contourEnd: CGPoint,
                                tangent: CGPoint,
                                segments: [SC.Segment],
                                z: Double) -> (exitPoint: CGPoint, move: SC.Waypoint)? {

        guard let leadOut else {
            return nil
        }

        switch leadOut.style {
            case .linear(let length):
                let exitPoint = CGPoint(x: contourEnd.x + tangent.x * length, y: contourEnd.y + tangent.y * length)
                let move = SC.Waypoint(position: SIMD3(exitPoint.x, exitPoint.y, z),
                                       motion: .linear,
                                       feedRate: leadOut.feedRate)
                return (exitPoint, move)

            case .arc(let radius, let sweepDegrees):
                let signedOffset = OffsetTools.offsetDistance(for: side, toolRadius: radius, segments: segments)
                let normal = CGPoint(x: -tangent.y, y: tangent.x)
                let center = CGPoint(x: contourEnd.x + normal.x * signedOffset, y: contourEnd.y + normal.y * signedOffset)
                let isCCW = signedOffset > 0
                let contourAngle = atan2(contourEnd.y - center.y, contourEnd.x - center.x)
                let sweepRad = sweepDegrees.degreesToRadians
                let exitAngle = isCCW ? contourAngle + sweepRad : contourAngle - sweepRad
                let exitPoint = CGPoint(x: center.x + radius * cos(exitAngle), y: center.y + radius * sin(exitAngle))
                let move = SC.Waypoint(position: SIMD3(exitPoint.x, exitPoint.y, z),
                                       motion: isCCW ? .arcCCW(center: center) : .arcCW(center: center),
                                       feedRate: leadOut.feedRate)
                return (exitPoint, move)
        }
    }

    // MARK: - Contour trace with holding tabs

    /// Traces `segments` at `z`, one waypoint per segment endpoint (mirrors the plain
    /// `.engrave` trace) -- except where a holding tab crosses this pass at a depth deeper
    /// than the tab's remaining-stock floor, in which case that waypoint's Z is clamped to
    /// the floor instead of the requested pass depth.
    ///
    /// Not converted to `throws` in Step 6.4: the `compactMap` below silently drops a tab
    /// whose span is degenerate (a zero-length path, or a ratio/width combination that
    /// resolves to an empty range) rather than erroring. A malformed tab that contributes
    /// nothing is the same as no tab at all from the toolpath's point of view -- there's no
    /// broken *toolpath* here, just one tab spec that turned out not to apply, so this stays
    /// "empty is a valid result" rather than "empty means something broke."
    private func tracedWaypoints(for segments: [SC.Segment],
                                 atZ z: Double,
                                 totalDepth: Double,
                                 tabs: [SC.HoldingTab],
                                 settings: SC.MachineSettings) -> [SC.Waypoint] {

        let totalLength = segments.reduce(0.0) { $0 + segmentLength($1) }

        // Tab spans in cumulative-distance-along-path terms, with the Z floor the tool must
        // not cut below while inside that span.
        let spans: [(range: ClosedRange<Double>, floorZ: Double)] = tabs.compactMap { tab in
            guard totalLength > 1e-9 else {
                return nil
            }
            let center = tab.positionRatio * totalLength
            let half = tab.width / 2.0
            let lower = max(0, center - half)
            let upper = min(totalLength, center + half)
            guard lower <= upper else {
                return nil
            }
            let floorZ = -(totalDepth - tab.height)

            return (lower...upper, floorZ)
        }

        var waypoints: [SC.Waypoint] = []
        var cumulative = 0.0
        for segment in segments {
            cumulative += segmentLength(segment)

            var effectiveZ = z
            for span in spans where span.range.contains(cumulative) && z < span.floorZ {
                effectiveZ = span.floorZ
            }

            switch segment {
                case .line(_, let end):
                    waypoints.append(
                        SC.Waypoint(position: SIMD3(end.x, end.y, effectiveZ), motion: .linear, feedRate: settings.cutting.feedRate)
                    )
                case .arc(let center, let radius, _, let endAngle, let isCCW):
                    let endX = center.x + radius * cos(endAngle)
                    let endY = center.y + radius * sin(endAngle)
                    waypoints.append(
                        SC.Waypoint(position: SIMD3(endX, endY, effectiveZ),
                                    motion: isCCW ? .arcCCW(center: center) : .arcCW(center: center),
                                    feedRate: settings.cutting.feedRate)
                    )
            }
        }
        return waypoints
    }

    private func segmentLength(_ segment: SC.Segment) -> Double {
        switch segment {
            case .line(let start, let end):
                return hypot(end.x - start.x, end.y - start.y)

            case .arc(_, let radius, let startAngle, let endAngle, let isCCW):
                let sweep = isCCW ? (endAngle - startAngle) : (startAngle - endAngle)
                return radius * abs(sweep)
        }
    }
}

extension SC.Contour {

    public var linearizedSegments: [SC.Segment] {
        var segments: [SC.Segment] = []

        for chained in self.entities {
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
                let start = startDeg.degreesToRadians
                var end = endDeg.degreesToRadians

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

            // TODO: If i import CoreGraphics the sin fails with an error
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
}
