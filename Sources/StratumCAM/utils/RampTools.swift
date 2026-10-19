//
//  RampTools.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 14.09.2026.
//

import Foundation
import simd

struct RampTools {
    /// Zig-zags back and forth near the first segment of the path, descending a fixed
    /// increment of Z per leg, until the requested `angleDegrees` has been honored -- then
    /// lands back exactly on the contour's start point at `toZ`, ready to hand off into the
    /// normal trace.
    static func rampWaypoints(firstSegment: SC.Segment,
                              angleDegrees: Double,
                              fromZ: Double,
                              toZ: Double,
                              settings: SC.MachineSettings) -> [SC.Waypoint] {

        let totalDrop = fromZ - toZ
        let angleRad = angleDegrees.degreesToRadians

        let a = firstSegment.startPoint
        let b = firstSegment.endPoint
        let spanLength = hypot(b.x - a.x, b.y - a.y)

        guard totalDrop > 1e-9, angleDegrees > 0, angleDegrees < 90, spanLength > 1e-9 else {
            // Degenerate ramp (already at depth, bad angle, or a zero-length first segment)
            // -- fall back to a straight plunge rather than produce nonsense geometry.
            return [SC.Waypoint(position: SIMD3(a.x, a.y, toZ),
                                motion: .linear,
                                feedRate: settings.cutting.plungeRate)]
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

    /// Ramps down while following the toolpath itself: the tool descends along the leading
    /// part of `path` (lines and arcs alike, so circular moves stay circular in XY and turn
    /// into helical arcs in XYZ), comes back along the same part, and repeats until
    /// `angleDegrees` is honored. It ends on the path's start point at `toZ`, ready for the
    /// normal trace. Since the path is already clear of walls and islands, so is the ramp.
    static func pathRampWaypoints(path: [SC.Segment],
                                  angleDegrees: Double,
                                  fromZ: Double,
                                  toZ: Double,
                                  settings: SC.MachineSettings) -> [SC.Waypoint] {

        let totalDrop = fromZ - toZ
        let pathLength = path.pathLength

        guard let start = path.first?.startPoint else {
            return []
        }
        guard totalDrop > 1e-9, angleDegrees > 0, angleDegrees < 90, pathLength > 1e-9 else {
            return [SC.Waypoint(position: SIMD3(start.x, start.y, toZ),
                                motion: .linear,
                                feedRate: settings.cutting.plungeRate)]
        }

        let horizontalRunNeeded = totalDrop / tan(angleDegrees.degreesToRadians)

        // Even number of legs (out and back) so the ramp finishes on the path start.
        var legCount = max(2, Int((horizontalRunNeeded / pathLength).rounded(.up)))
        if legCount % 2 != 0 { legCount += 1 }

        let legLength = min(pathLength, horizontalRunNeeded / Double(legCount))
        let dropPerLeg = totalDrop / Double(legCount)

        let forward = prefix(of: path, length: legLength)
        let backward = forward.reversed().map { $0.reversed }

        var waypoints: [SC.Waypoint] = []
        for leg in 0..<legCount {
            let segments = leg % 2 == 0 ? forward : backward
            let legStartZ = fromZ - dropPerLeg * Double(leg)
            var travelled = 0.0
            for (index, segment) in segments.enumerated() {
                travelled += segment.pathLength
                let isLastOfRamp = leg == legCount - 1 && index == segments.count - 1
                let z = isLastOfRamp ? toZ : legStartZ - dropPerLeg * min(1.0, travelled / legLength)
                switch segment {
                    case .line(_, let end):
                        waypoints.append(SC.Waypoint(position: SIMD3(end.x, end.y, z),
                                                     motion: .linear,
                                                     feedRate: settings.cutting.plungeRate))
                    case .arc(let center, let radius, _, let endAngle, let isCCW):
                        waypoints.append(SC.Waypoint(position: SIMD3(center.x + radius * cos(endAngle),
                                                                     center.y + radius * sin(endAngle),
                                                                     z),
                                                     motion: isCCW ? .arcCCW(center: center) : .arcCW(center: center),
                                                     feedRate: settings.cutting.plungeRate))
                }
            }
        }
        return waypoints
    }

    /// The first `length` of `path` (all of it when it is shorter).
    private static func prefix(of path: [SC.Segment], length: Double) -> [SC.Segment] {
        var result: [SC.Segment] = []
        var remaining = length
        for segment in path {
            let segmentLength = segment.pathLength
            if segmentLength <= remaining + 1e-9 {
                result.append(segment)
                remaining -= segmentLength
                if remaining <= 1e-9 { break }
                continue
            }
            switch segment {
                case .line(let a, let b):
                    let t = remaining / segmentLength
                    result.append(.line(start: a, end: CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))))
                case .arc(let center, let radius, let startAngle, _, let isCCW):
                    let sweep = remaining / radius
                    result.append(.arc(center: center,
                                       radius: radius,
                                       startAngle: startAngle,
                                       endAngle: startAngle + (isCCW ? sweep : -sweep),
                                       isCCW: isCCW))
            }
            break
        }
        return result
    }

    /// Spirals down a circle of `radius`, centered off to the side with no material (so the
    /// tool never gouges the wall while descending), positioned so `contourStart` sits
    /// exactly on the circle. Always completes a whole number of turns, so it lands back on
    /// `contourStart` at `toZ`, tangent and ready to continue into the profile trace.
    ///
    /// The perpendicular (normal) offset alone only keeps the circle clear of the wall
    /// that runs *along* `startTangent` -- it says nothing about the direction *behind*
    /// `contourStart` (the `-startTangent` side). For a point that sits exactly on a wall
    /// running parallel to the tangent right where the tool is about to enter -- which is
    /// exactly what a raster row's start point is, since each row is clipped to end
    /// precisely on the wall offset boundary -- the full circle still extends `radius`
    /// behind `contourStart` along `-startTangent`, straight through that wall, no matter
    /// which way the perpendicular offset is signed. `rampWaypoints` above sidesteps this
    /// by never stepping backward past its anchor point at all; the helix borrows the same
    /// idea: it spirals tangent to a point shifted `radius` *forward* along the segment
    /// (clamped to the segment's own length, so it never runs off the far end either) and
    /// finishes with a short linear cut from there back to the true `contourStart` -- so
    /// the circle's backward extent lands exactly on `contourStart`'s wall, not past it.
    ///
    /// Internal rather than `private` so `SCEngine+Pocketing.swift` can reuse it for
    /// pocket entry (Step 1.2) instead of duplicating the helix geometry.
    static func helixEntryWaypoints(contourStart: CGPoint,
                                    startTangent: CGPoint,
                                    side: SC.CutSide,
                                    segments: [SC.Segment],
                                    firstSegment: SC.Segment,
                                    radius: Double,
                                    angleDegrees: Double,
                                    fromZ: Double,
                                    toZ: Double,
                                    settings: SC.MachineSettings) -> [SC.Waypoint] {

        let totalDrop = fromZ - toZ
        let angleRad = angleDegrees.degreesToRadians

        guard totalDrop > 1e-9, angleDegrees > 0, angleDegrees < 90, radius > 1e-9 else {
            return [SC.Waypoint(position: SIMD3(contourStart.x, contourStart.y, toZ),
                                motion: .linear,
                                feedRate: settings.cutting.plungeRate)]
        }

        // Shift the circle's tangent point `radius` forward along the segment -- clamped
        // to the segment's own length, same clamp `rampWaypoints` applies to `legRun` --
        // so the circle's backward reach lands exactly on `contourStart` instead of
        // punching through whatever wall it sits on.
        let anchorEnd = firstSegment.endPoint
        let spanLength = hypot(anchorEnd.x - contourStart.x, anchorEnd.y - contourStart.y)
        let forwardDistance = min(radius, spanLength)
        let tangentPoint = CGPoint(x: contourStart.x + startTangent.x * forwardDistance,
                                    y: contourStart.y + startTangent.y * forwardDistance)

        let signedOffset = OffsetTools.offsetDistance(for: side, toolRadius: radius, segments: segments)
        let normal = CGPoint(x: -startTangent.y, y: startTangent.x)
        let center = CGPoint(x: tangentPoint.x + normal.x * signedOffset, y: tangentPoint.y + normal.y * signedOffset)
        let isCCW = signedOffset > 0
        let startAngle = atan2(tangentPoint.y - center.y, tangentPoint.x - center.x)

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

        // The spiral itself lands on `tangentPoint`, not `contourStart` -- bridge the
        // small gap between them (a no-op when the segment was too short to shift at
        // all) so callers can keep relying on the helix landing exactly on `contourStart`
        // at `toZ`, ready to hand off into the trace.
        if forwardDistance > 1e-9 {
            waypoints.append(
                SC.Waypoint(position: SIMD3(contourStart.x, contourStart.y, toZ),
                            motion: .linear,
                            feedRate: settings.cutting.plungeRate)
            )
        }

        return waypoints
    }
}
