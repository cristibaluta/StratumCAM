//
//  SCEngine+Contour.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// Shared pipeline behind `.engrave` and (for now) `.contour`: linearize the contour,
    /// optionally apply tool-radius compensation, step down through Z, and trace the
    /// resulting segments once per pass. The `strategy` passed in is the one actually
    /// requested by the caller, so the output is tagged accurately instead of hardcoded.
    func buildContourTracingToolpath(for contour: SC.Contour,
                                     tool: SC.ToolParams,
                                     settings: SC.MachineSettings,
                                     side: SC.CutSide,
                                     operation: SC.MachiningOperation) -> SC.OutputToolpath? {

        // 1. Normalize DXF Entities into linear/arc segments (handling reversed flag)
        let baseSegments = linearize(contour: contour)
        guard !baseSegments.isEmpty else {
            return nil
        }

        // 1b. Apply tool-radius compensation for inside/outside profile cuts
        let toolpathSegments = offsetContour(baseSegments,
                                             side: side,
                                             toolRadius: tool.diameter / 2.0,
                                             isClosed: contour.isClosed)

        // 2. Calculate Z depth passes based on the configured cutting stepdown
        let zDepths = calculateZPasses(targetDepth: settings.targetDepth, stepdown: settings.cutting.stepdown)

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
    func buildContourToolpath(for contour: SC.Contour,
                              tool: SC.ToolParams,
                              settings: SC.MachineSettings,
                              side: SC.CutSide,
                              direction cutDirection: SC.CutDirection,
                              entry: SC.EntryStrategy,
                              leadIn: SC.LeadInOut?,
                              leadOut: SC.LeadInOut?,
                              tabs: [SC.HoldingTab],
                              operation: SC.MachiningOperation) -> SC.OutputToolpath? {

        let baseSegments = linearize(contour: contour)
        guard !baseSegments.isEmpty else {
            return nil
        }

        // 1. Orient the chain so travel direction matches the requested climb/conventional cut.
        let oriented = orientedForDirection(baseSegments, side: side, direction: cutDirection)

        // 2. Tool-radius compensation (existing offset engine).
        let toolpathSegments = offsetContour(oriented, side: side, toolRadius: tool.diameter / 2.0, isClosed: contour.isClosed)
        guard let firstSegment = toolpathSegments.first else {
            return nil
        }

        let zDepths = calculateZPasses(targetDepth: settings.targetDepth, stepdown: settings.cutting.stepdown)
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

        guard isCCWWinding(segments) != wantsCCW else {
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

        let contourStart = startPointOf(segment: firstSegment)
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
                    contentsOf: rampWaypoints(firstSegment: firstSegment,
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
                    contentsOf: helixEntryWaypoints(contourStart: contourStart,
                                                    startTangent: startTangent,
                                                    side: side,
                                                    segments: segments,
                                                    radius: radius,
                                                    angleDegrees: angleDegrees,
                                                    fromZ: previousZ,
                                                    toZ: z,
                                                    settings: settings)
                )
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

    // MARK: - Entry: ramp

    /// Zig-zags back and forth near the first segment of the path, descending a fixed
    /// increment of Z per leg, until the requested `angleDegrees` has been honored -- then
    /// lands back exactly on the contour's start point at `toZ`, ready to hand off into the
    /// normal trace.
    private func rampWaypoints(firstSegment: SC.Segment,
                               angleDegrees: Double,
                               fromZ: Double,
                               toZ: Double,
                               settings: SC.MachineSettings) -> [SC.Waypoint] {

        let totalDrop = fromZ - toZ
        let angleRad = angleDegrees * .pi / 180.0

        let a = firstSegment.startPoint
        let b = firstSegment.endPoint
        let spanLength = hypot(b.x - a.x, b.y - a.y)

        guard totalDrop > 1e-9, angleDegrees > 0, angleDegrees < 90, spanLength > 1e-9 else {
            // Degenerate ramp (already at depth, bad angle, or a zero-length first segment)
            // -- fall back to a straight plunge rather than produce nonsense geometry.
            return [SC.Waypoint(position: SIMD3(a.x, a.y, toZ), motion: .linear, feedRate: settings.cutting.plungeRate)]
        }

        // Total horizontal distance the tool must travel, at `angleDegrees`, to cover
        // `totalDrop`. This -- not the anchor segment's own length -- is what determines
        // how far each leg actually swings: a shallow stepdown at a shallow angle only
        // needs a short back-and-forth near the contour start, not a swing across the
        // whole segment.
        let horizontalRunNeeded = totalDrop / tan(angleRad)

        // How many out-and-back legs are needed so no single leg has to run further than
        // the anchor segment itself allows, rounded up to an even count so the ramp always
        // finishes back at `a` (the contour start).
        var legCount = max(2, Int((horizontalRunNeeded / spanLength).rounded(.up)))
        if legCount % 2 != 0 { legCount += 1 }

        // Spreading the required run evenly across every leg keeps each leg's achieved
        // angle exactly `angleDegrees` (not shallower), and naturally caps each leg's
        // travel at `spanLength` since `legCount` was sized for that.
        let legRun = min(spanLength, horizontalRunNeeded / Double(legCount))
        let dropPerLeg = totalDrop / Double(legCount)

        let dirX = (b.x - a.x) / spanLength
        let dirY = (b.y - a.y) / spanLength
        let forwardPoint = CGPoint(x: a.x + dirX * legRun, y: a.y + dirY * legRun)

        var waypoints: [SC.Waypoint] = []
        var currentZ = fromZ
        for leg in 0..<legCount {
            let target = leg % 2 == 0 ? forwardPoint : a
            currentZ = (leg == legCount - 1) ? toZ : currentZ - dropPerLeg
            waypoints.append(
                SC.Waypoint(position: SIMD3(target.x, target.y, currentZ),
                            motion: .linear,
                            feedRate: settings.cutting.plungeRate)
            )
        }
        return waypoints
    }

    // MARK: - Entry: helix

    /// Spirals down a circle of `radius`, centered off to the side with no material (so the
    /// tool never gouges the wall while descending), positioned so `contourStart` sits
    /// exactly on the circle. Always completes a whole number of turns, so it lands back on
    /// `contourStart` at `toZ`, tangent and ready to continue into the profile trace.
    private func helixEntryWaypoints(contourStart: CGPoint,
                                     startTangent: CGPoint,
                                     side: SC.CutSide,
                                     segments: [SC.Segment],
                                     radius: Double,
                                     angleDegrees: Double,
                                     fromZ: Double,
                                     toZ: Double,
                                     settings: SC.MachineSettings) -> [SC.Waypoint] {

        let totalDrop = fromZ - toZ
        let angleRad = angleDegrees * .pi / 180.0

        guard totalDrop > 1e-9, angleDegrees > 0, angleDegrees < 90, radius > 1e-9 else {
            return [SC.Waypoint(position: SIMD3(contourStart.x, contourStart.y, toZ), motion: .linear, feedRate: settings.cutting.plungeRate)]
        }

        let signedOffset = offsetDistance(for: side, toolRadius: radius, segments: segments)
        let normal = CGPoint(x: -startTangent.y, y: startTangent.x)
        let center = CGPoint(x: contourStart.x + normal.x * signedOffset, y: contourStart.y + normal.y * signedOffset)
        let isCCW = signedOffset > 0
        let startAngle = atan2(contourStart.y - center.y, contourStart.x - center.x)

        let circumference = 2 * .pi * radius
        let horizontalRunNeeded = totalDrop / tan(angleRad)
        let turns = max(1, Int((horizontalRunNeeded / circumference).rounded(.up)))
        let stepsPerTurn = 8
        let stepCount = turns * stepsPerTurn
        let sweepPerStep = (2 * .pi / Double(stepsPerTurn)) * (isCCW ? 1.0 : -1.0)
        let dropPerStep = totalDrop / Double(stepCount)

        var waypoints: [SC.Waypoint] = []
        var currentZ = fromZ
        for step in 1...stepCount {
            let angle = startAngle + sweepPerStep * Double(step)
            currentZ = (step == stepCount) ? toZ : currentZ - dropPerStep
            let x = center.x + radius * cos(angle)
            let y = center.y + radius * sin(angle)
            waypoints.append(
                SC.Waypoint(position: SIMD3(x, y, currentZ),
                            motion: isCCW ? .arcCCW(center: center) : .arcCW(center: center),
                            feedRate: settings.cutting.plungeRate)
            )
        }
        return waypoints
    }

    // MARK: - Lead-in / lead-out (plunge entry only, see file header)

    /// Resolves where a `.plunge` entry should actually land, and the extra waypoint that
    /// carries the tool from there onto `contourStart`, for a given `LeadInOut` style.
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
                let signedOffset = offsetDistance(for: side, toolRadius: radius, segments: segments)
                let normal = CGPoint(x: -tangent.y, y: tangent.x)
                let center = CGPoint(x: contourStart.x + normal.x * signedOffset, y: contourStart.y + normal.y * signedOffset)
                let isCCW = signedOffset > 0
                let contourAngle = atan2(contourStart.y - center.y, contourStart.x - center.x)
                let sweepRad = sweepDegrees * .pi / 180.0
                // Walk backwards from the contour point to find where the lead-in arc starts.
                let entryAngle = isCCW ? contourAngle - sweepRad : contourAngle + sweepRad
                let entryPoint = CGPoint(x: center.x + radius * cos(entryAngle), y: center.y + radius * sin(entryAngle))
                let move = SC.Waypoint(position: SIMD3(contourStart.x, contourStart.y, z),
                                       motion: isCCW ? .arcCCW(center: center) : .arcCW(center: center),
                                       feedRate: leadIn.feedRate)
                return (entryPoint, move)
        }
    }

    /// Mirror of `resolveLeadIn` for the departure end of the cut.
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
                let signedOffset = offsetDistance(for: side, toolRadius: radius, segments: segments)
                let normal = CGPoint(x: -tangent.y, y: tangent.x)
                let center = CGPoint(x: contourEnd.x + normal.x * signedOffset, y: contourEnd.y + normal.y * signedOffset)
                let isCCW = signedOffset > 0
                let contourAngle = atan2(contourEnd.y - center.y, contourEnd.x - center.x)
                let sweepRad = sweepDegrees * .pi / 180.0
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
