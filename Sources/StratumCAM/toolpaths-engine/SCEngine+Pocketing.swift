//
//  SCEngine+Pocketing.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import CoreGraphics

extension SCEngine {

    func buildPocketToolpath(for contour: SC.Contour,
                             tool: SC.ToolParams,
                             settings: SC.MachineSettings,
                             direction: SC.CutDirection,
                             pattern: SC.PocketClearingPattern,
                             entry: SC.EntryStrategy,
                             operation: SC.MachiningOperation) throws -> SC.OutputToolpath {

        guard contour.isClosed else {
            throw SC.Error.contourNotClosed
        }

        // Reject entry parameters that the ramp/helix helpers would otherwise silently
        // turn into a straight plunge.
        switch entry {
            case .ramp(let angleDegrees):
                guard angleDegrees > 0, angleDegrees < 90 else {
                    throw SC.Error.invalidParameter("entry.ramp.angleDegrees")
                }
            case .helix(let angleDegrees):
                guard angleDegrees > 0, angleDegrees < 90 else {
                    throw SC.Error.invalidParameter("entry.helix.rampAngleDegrees")
                }
            case .plunge, .fromOpenEnd:
                break
        }

        let baseSegments = contour.linearizedSegments
        guard !baseSegments.isEmpty else {
            throw SC.Error.invalidContour
        }

        // Islands would be gouged by any pattern that doesn't know about them, so refuse
        // instead of silently cutting through.
        if !contour.islands.isEmpty {
            guard case .concentric = pattern else {
                throw SC.Error.invalidParameter("islands are only supported by the .concentric pattern")
            }
            switch entry {
                case .plunge, .fromOpenEnd, .ramp:
                    break
                case .helix:
                    throw SC.Error.invalidParameter("islands support plunge and ramp entries only")
            }
        }

        var timingClock = OffsetTiming.now()
        let toolpathSegments: [SC.Segment]

        // The real, closed pocket-wall boundary
        let boundarySegments: [SC.Segment]

        // Set when islands split the toolpath into separately-plunged groups.
        var islandGroups: [[SC.Segment]]?

        switch pattern {
            case .offset:
                // 1. Orient the chain so travel direction matches the requested cut
                // direction. Pocket walls are inside cuts, so use `.inside` for the same
                // climb/conventional convention already established by profile.
                let oriented = orientedForDirection(baseSegments, side: .inside, direction: direction)
                boundarySegments = oriented

                // 2. Generate the concentric ring stack, geometry only (Step 2.2a, done).
                let rings = pocketRings(from: oriented, tool: tool, stepoverPercentage: settings.cutting.stepoverPercentage)
                guard !rings.isEmpty else {
                    throw SC.Error.geometryCollapsed
                }

                toolpathSegments = chainedRingSegments(rings)

            case .concentric(let ringOrder):
                let oriented = orientedForDirection(baseSegments, side: .inside, direction: direction)
                boundarySegments = oriented

                let rings = pocketRings(from: oriented, tool: tool, stepoverPercentage: settings.cutting.stepoverPercentage)
                guard !rings.isEmpty else {
                    throw SC.Error.geometryCollapsed
                }

                // Inside-out ring stack.
                //  - An island-free axis-aligned rectangle gets rings that start as a circle (or a
                //    slot for a long rectangle) at the centre and sharpen into the rectangle at
                //    the wall.
                //  - Any other shape (irregular, or with islands) starts with circles around the
                //    point furthest from every wall and island, grown until the biggest touches
                //    something, then continues with the wall offset rings.
                //  - If no such centre can be found, the plain offset rings, reversed.
                let toolRadius = tool.diameter / 2.0
                let stepover = settings.cutting.stepoverPercentage * tool.diameter
                let zones: [PocketIslandZone] = try contour.islands.isEmpty
                    ? []
                    : islandZones(contour.islands, toolRadius: toolRadius, wallRing: rings[0])

                OffsetTiming.log("[pocket] pocketRings: \(OffsetTiming.lap(&timingClock)) ms (\(rings.count) rings)")
                let insideOutRings: [[SC.Segment]]
                if zones.isEmpty, let morphed = roundedMorphRings(wallRing: rings[0], toolRadius: toolRadius, stepover: stepover) {
                    OffsetTiming.log("[pocket] roundedMorphRings: \(OffsetTiming.lap(&timingClock)) ms")
                    insideOutRings = morphed
                } else if let centered = centeredRings(offsetRings: rings, zones: zones, toolRadius: toolRadius, stepover: stepover) {
                    OffsetTiming.log("[pocket] centeredRings: \(OffsetTiming.lap(&timingClock)) ms")
                    insideOutRings = centered
                } else {
                    insideOutRings = Array(rings.reversed())
                }

                let orderedRings = ringOrder == .insideOut ? insideOutRings : Array(insideOutRings.reversed())

                if zones.isEmpty {
                    toolpathSegments = chainedRingSegments(orderedRings)
                } else {
                    let groups = islandRingGroups(rings: orderedRings, zones: zones, wallRing: rings[0])
                    guard !groups.isEmpty else {
                        throw SC.Error.geometryCollapsed
                    }
                    islandGroups = groups
                    toolpathSegments = groups.flatMap { $0 }
                }

            case .raster:

                let wallOffset = offsetContour(baseSegments, side: .inside, toolRadius: tool.diameter / 2.0, isClosed: true)
                guard !wallOffset.isEmpty else {
                    throw SC.Error.geometryCollapsed
                }
                boundarySegments = wallOffset

                let stepover = settings.cutting.stepoverPercentage * tool.diameter
                let rows = rasterScanlines(within: wallOffset, stepover: stepover, direction: direction)
                guard !rows.isEmpty else {
                    throw SC.Error.geometryCollapsed
                }

                // Rows alternate direction, so half of them are inherently conventional.
                // Close with a wall finishing loop in the requested direction, starting
                // where the last row ended so the link between them is a no-op.
                var chained = chainedRingSegments(rows)
                let orientedWall = orientedForDirection(wallOffset, side: .inside, direction: direction)
                let finishing = chained.last.map { rotatedLoop(orientedWall, startingAt: $0.endPoint) } ?? orientedWall
                if let previousEnd = chained.last?.endPoint, let loopStart = finishing.first?.startPoint,
                   hypot(loopStart.x - previousEnd.x, loopStart.y - previousEnd.y) > 1e-6 {
                    chained.append(.line(start: previousEnd, end: loopStart))
                }
                chained.append(contentsOf: finishing)
                toolpathSegments = chained

            case .spiral(let spiralDirection):

                let oriented = orientedForDirection(baseSegments, side: .inside, direction: direction)
                boundarySegments = oriented

                let rings = pocketRings(from: oriented, tool: tool, stepoverPercentage: settings.cutting.stepoverPercentage)
                guard !rings.isEmpty else {
                    throw SC.Error.geometryCollapsed
                }

                if isSpiralEligible(oriented) {
                    toolpathSegments = spiralSegments(from: rings, direction: spiralDirection)
                } else {
                    toolpathSegments = chainedRingSegments(rings)
                }

            case .trochoidal(let trochoidalSettings):

                let oriented = orientedForDirection(baseSegments, side: .inside, direction: direction)
                boundarySegments = oriented

                let rings = pocketRings(from: oriented, tool: tool, stepoverPercentage: settings.cutting.stepoverPercentage)
                guard !rings.isEmpty else {
                    throw SC.Error.geometryCollapsed
                }

                let stepover = settings.cutting.stepoverPercentage * tool.diameter
                var chained: [SC.Segment] = []
                for ring in rings {
                    let bounced = ringTrochoidalSegments(from: ring,
                                                         tool: tool,
                                                         bandWidth: stepover,
                                                         radialEngagement: trochoidalSettings.radialEngagement)
                    guard !bounced.isEmpty else {
                        continue
                    }

                    if let previousEnd = chained.last?.endPoint {
                        let ringStart = bounced[0].startPoint
                        if hypot(ringStart.x - previousEnd.x, ringStart.y - previousEnd.y) > 1e-6 {
                            chained.append(.line(start: previousEnd, end: ringStart))
                        }
                    }
                    chained.append(contentsOf: bounced)
                }
                toolpathSegments = chained

            case .adaptive:
                // Not implemented yet -- surface it as an error instead of crashing the caller.
                throw SC.Error.invalidParameter("pattern: .adaptive is not implemented")
        }

        guard !toolpathSegments.isEmpty else {
            throw SC.Error.geometryCollapsed
        }
        OffsetTiming.log("[pocket] \(pattern) toolpath segments: \(OffsetTiming.lap(&timingClock)) ms (\(toolpathSegments.count) segments)")

        let zDepths = EngineTools.calculateZPasses(targetDepth: settings.targetDepth, stepdown: settings.cutting.stepdown)

        // Where the tool centre may be (the wall offset by the tool radius) and which way the
        // cut winds -- only a helix entry needs them, to place its circle inside the pocket.
        var toolCenterRegion: [SC.Segment] = []
        var helixIsCCW = true
        if case .helix = entry {
            if case .raster = pattern {
                toolCenterRegion = boundarySegments // already the wall offset
            } else {
                toolCenterRegion = offsetContour(boundarySegments, side: .inside, toolRadius: tool.diameter / 2.0, isClosed: true)
            }
            if !toolCenterRegion.isEmpty {
                helixIsCCW = OffsetTools.isCCWWinding(orientedForDirection(toolCenterRegion, side: .inside, direction: direction))
            }
        }

        OffsetTiming.log("[pocket] tool-centre region: \(OffsetTiming.lap(&timingClock)) ms")

        var passes: [SC.ToolpathPass] = []
        var previousZ = 0.0 // top of stock -- pass 0 ramps/helixes down from here, same convention `.contour` uses.
        for (i, z) in zDepths.enumerated() {
            let waypoints: [SC.Waypoint]
            if let groups = islandGroups {
                // Each group is entered and retracted on its own so no move crosses an island.
                waypoints = groups.flatMap {
                    buildIslandGroupWaypoints(for: $0, atZ: z, previousZ: previousZ, settings: settings, entry: entry)
                }
            } else {
                waypoints = buildEntryWaypoints(for: toolpathSegments,
                                                boundary: boundarySegments,
                                                toolRadius: tool.diameter / 2.0,
                                                toolCenterRegion: toolCenterRegion,
                                                helixIsCCW: helixIsCCW,
                                                atZ: z,
                                                previousZ: previousZ,
                                                settings: settings,
                                                entry: entry)
            }
            passes.append(SC.ToolpathPass(passIndex: i, depthZ: z, waypoints: waypoints))
            OffsetTiming.log("[pocket] pass \(i) entry waypoints: \(OffsetTiming.lap(&timingClock)) ms (\(waypoints.count) waypoints)")
            previousZ = z
        }

        if settings.retractPolicy != .safeZ, islandGroups == nil, passes.count > 1 {
            // Where the tool centre may travel between layers: already the wall offset for
            // raster and for helix entries, otherwise offset it here.
            var travelRegion = toolCenterRegion
            if travelRegion.isEmpty {
                if case .raster = pattern {
                    travelRegion = boundarySegments
                } else {
                    travelRegion = offsetContour(boundarySegments, side: .inside, toolRadius: tool.diameter / 2.0, isClosed: true)
                }
            }
            applyRetractPolicy(to: &passes, region: travelRegion, settings: settings)
        }

        return SC.OutputToolpath(operation: operation,
                                 tool: tool,
                                 settings: settings,
                                 passes: passes,
                                 restCorners: restCorners(in: baseSegments, toolRadius: tool.diameter / 2.0))
    }

    /// Replaces the full retract / re-approach at safe Z between two consecutive layers with
    /// the move `settings.retractPolicy` asks for. Layers whose link would leave `region`
    /// keep the full retract. Expects every pass to start with a rapid at safe Z and end with
    /// a rapid back to safe Z, which is what the entry builders produce.
    private func applyRetractPolicy(to passes: inout [SC.ToolpathPass], region: [SC.Segment], settings: SC.MachineSettings) {
        guard !region.isEmpty else {
            return
        }
        for i in 0..<(passes.count - 1) {
            var current = passes[i].waypoints
            var next = passes[i + 1].waypoints
            guard current.count >= 2, let nextStart = next.first,
                  let last = current.last, last.motion == .rapid,
                  nextStart.motion == .rapid else {
                continue
            }
            let cutEnd = current[current.count - 2].position
            let from = CGPoint(x: cutEnd.x, y: cutEnd.y)
            let to = CGPoint(x: nextStart.position.x, y: nextStart.position.y)
            guard linkStaysInside(from: from, to: to, wallRing: region) else {
                continue
            }

            let hoverZ: Double
            switch settings.retractPolicy {
                case .safeZ:
                    continue
                case .clearance:
                    hoverZ = min(cutEnd.z + settings.retractZ, settings.safeZ)
                case .none:
                    hoverZ = cutEnd.z
            }

            if hoverZ == cutEnd.z {
                current.removeLast()
            } else {
                current[current.count - 1] = SC.Waypoint(position: SIMD3(cutEnd.x, cutEnd.y, hoverZ),
                                                         motion: .rapid,
                                                         feedRate: last.feedRate)
            }
            next[0] = SC.Waypoint(position: SIMD3(nextStart.position.x, nextStart.position.y, hoverZ),
                                  motion: .rapid,
                                  feedRate: nextStart.feedRate)
            passes[i] = SC.ToolpathPass(passIndex: passes[i].passIndex, depthZ: passes[i].depthZ, waypoints: current)
            passes[i + 1] = SC.ToolpathPass(passIndex: passes[i + 1].passIndex, depthZ: passes[i + 1].depthZ, waypoints: next)
        }
    }

    // MARK: - Pocket entry

    /// One island group: plunged as usual, or, for `.ramp`, descended along the group's own
    /// path (arcs stay arcs) instead of dropping straight down at its start.
    private func buildIslandGroupWaypoints(for group: [SC.Segment],
                                           atZ z: Double,
                                           previousZ: Double,
                                           settings: SC.MachineSettings,
                                           entry: SC.EntryStrategy) -> [SC.Waypoint] {
        guard case .ramp(let angleDegrees) = entry,
              let start = group.first?.startPoint,
              let ramped = RampTools.pathRampWaypoints(path: group,
                                                       angleDegrees: angleDegrees,
                                                       fromZ: previousZ,
                                                       toZ: z,
                                                       settings: settings) else {
            // Plunge, or a group too short to ramp at this angle.
            return buildWaypoints(for: group, atZ: z, settings: settings)
        }
        // Ramp forward along the group's own path, then carry on tracing from where it ends.
        let ramp = [
            SC.Waypoint(position: SIMD3(start.x, start.y, settings.safeZ), motion: .rapid, feedRate: settings.cutting.feedRate),
            SC.Waypoint(position: SIMD3(start.x, start.y, previousZ), motion: .rapid, feedRate: settings.cutting.feedRate)
        ] + ramped.ramp
        // Reuse the trace + retract of `buildWaypoints`, dropping its own rapid and plunge.
        guard !ramped.remaining.isEmpty else {
            let end = ramped.ramp.last?.position ?? SIMD3(start.x, start.y, z)
            return ramp + [SC.Waypoint(position: SIMD3(end.x, end.y, settings.safeZ), motion: .rapid, feedRate: settings.cutting.feedRate)]
        }
        let trace = buildWaypoints(for: ramped.remaining, atZ: z, settings: settings).dropFirst(2)
        return ramp + trace
    }

    private func buildEntryWaypoints(for segments: [SC.Segment],
                                     boundary: [SC.Segment],
                                     toolRadius: Double,
                                     toolCenterRegion: [SC.Segment],
                                     helixIsCCW: Bool,
                                     atZ z: Double,
                                     previousZ: Double,
                                     settings: SC.MachineSettings,
                                     entry: SC.EntryStrategy) -> [SC.Waypoint] {

        guard let firstSegment = segments.first else {
            return []
        }

        // TODO: this is a mess, the entrypoint should be extracted to separate method and buildWaypoints should be reused
        // Perhaps add also an exitwaypoints?

        // `.fromOpenEnd` has no trochoidal feed-in outside `.slotting`; here it means the
        // start is in free air, so it plunges like `.plunge` does.
        guard !entry.isStraightDown else {
            return buildWaypoints(for: segments, atZ: z, settings: settings)
        }

        let startPoint = firstSegment.startPoint
        let startTangent = direction(of: firstSegment, atEnd: false)

        var waypoints: [SC.Waypoint] = [
            SC.Waypoint(position: SIMD3(startPoint.x, startPoint.y, settings.safeZ),
                        motion: .rapid,
                        feedRate: settings.cutting.feedRate)
        ]
        var traceSegments = segments

        switch entry {
            case .plunge:
                break // Handled above via `buildWaypoints`.

            case .ramp(let angleDegrees):
                // Travel at safeZ, but rapid down to previousZ first -- same fix
                // `buildProfileWaypoints`/`buildCounterboreWaypoints` already apply:
                // `RampTools.rampWaypoints` assumes the tool is already positioned at
                // `(start XY, previousZ)` when its own waypoint list begins, it doesn't
                // establish that position itself. Without this step the tessellated
                // render -- and the actual toolpath -- shows a straight drop from
                // safeZ before the ramp visibly starts, instead of starting at
                // previousZ (0 / top-of-stock on the first pass) the way it's supposed to.
                waypoints.append(
                    SC.Waypoint(position: SIMD3(startPoint.x, startPoint.y, previousZ),
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

            case .helix(let angleDegrees):
                // Same reasoning as `.ramp` above.
                let desiredRadius = RampTools.helixRadius(forToolRadius: toolRadius)

                // Where the helix goes. In a pocket that starts with a circle around its own
                // center (inside-out on round shapes) it is centered on that circle, and the
                // circles it already clears are skipped. Anywhere else, the helix center is
                // moved in from the start point just enough that the circle stays inside the
                // pocket, and after the helix the tool travels back to the start point.
                var helix: (center: CGPoint, radius: Double, startAngle: Double, isCCW: Bool)?
                var skipsClearedCircles = false

                if let circle = RampTools.leadingCircle(of: segments) {
                    // At most what fits in the pocket.
                    let clearance = boundary.map { distance(from: circle.center, to: $0) }.min() ?? .infinity
                    let helixRadius = max(1e-6, min(desiredRadius, clearance - toolRadius))
                    helix = (circle.center, helixRadius, circle.startAngle, circle.isCCW)
                    skipsClearedCircles = true
                } else if let fit = fittedHelix(start: startPoint, region: toolCenterRegion, desiredRadius: desiredRadius) {
                    // Start on the helix circle at the point nearest the pocket's start point.
                    let angle: Double = atan2(startPoint.y - fit.center.y, startPoint.x - fit.center.x)
                    helix = (fit.center, fit.radius, angle, helixIsCCW)
                }

                if let helix {
                    let helixStart = CGPoint(x: helix.center.x + helix.radius * cos(helix.startAngle),
                                             y: helix.center.y + helix.radius * sin(helix.startAngle))
                    // Come down over the helix start, not over the pocket's start point.
                    waypoints[0] = SC.Waypoint(position: SIMD3(helixStart.x, helixStart.y, settings.safeZ),
                                               motion: .rapid,
                                               feedRate: settings.cutting.feedRate)
                    waypoints.append(
                        SC.Waypoint(position: SIMD3(helixStart.x, helixStart.y, previousZ),
                                    motion: .rapid,
                                    feedRate: settings.cutting.feedRate)
                    )
                    waypoints.append(
                        contentsOf: RampTools.centeredHelixWaypoints(center: helix.center,
                                                                     radius: helix.radius,
                                                                     startAngle: helix.startAngle,
                                                                     isCCW: helix.isCCW,
                                                                     angleDegrees: angleDegrees,
                                                                     fromZ: previousZ,
                                                                     toZ: z,
                                                                     settings: settings)
                    )
                    // The floor under the last turn is still sloped: one flat full circle at
                    // depth cleans it.
                    waypoints.append(
                        contentsOf: RampTools.flatCircleWaypoints(center: helix.center,
                                                                  radius: helix.radius,
                                                                  startAngle: helix.startAngle,
                                                                  isCCW: helix.isCCW,
                                                                  z: z,
                                                                  feedRate: settings.cutting.feedRate)
                    )
                    if skipsClearedCircles {
                        // Rings that lie inside the helix are already cleared: carry on from
                        // the first ring beyond it.
                        traceSegments = RampTools.droppingCircles(upToRadius: helix.radius + 1e-6, from: segments)
                    }
                    // Travel to where the pocket's own toolpath begins, then trace it.
                    if let next = traceSegments.first?.startPoint,
                       hypot(next.x - helixStart.x, next.y - helixStart.y) > 1e-9 {
                        waypoints.append(
                            SC.Waypoint(position: SIMD3(next.x, next.y, z),
                                        motion: .linear,
                                        feedRate: settings.cutting.feedRate)
                        )
                    }
                } else {
                    // No usable clearance to place a helix in: the legacy sideways helix.
                    waypoints.append(
                        SC.Waypoint(position: SIMD3(startPoint.x, startPoint.y, previousZ),
                                    motion: .rapid,
                                    feedRate: settings.cutting.feedRate)
                    )
                    waypoints.append(
                        contentsOf: RampTools.helixEntryWaypoints(contourStart: startPoint,
                                                                  startTangent: startTangent,
                                                                  side: .inside,
                                                                  segments: boundary,
                                                                  firstSegment: firstSegment,
                                                                  radius: desiredRadius,
                                                                  angleDegrees: angleDegrees,
                                                                  fromZ: previousZ,
                                                                  toZ: z,
                                                                  settings: settings)
                    )
                }
            case .fromOpenEnd:
                break // Handled above via `buildWaypoints`.
        }

        // Trace the chained pocket geometry -- mirrors `buildWaypoints`' own trace step.
        for segment in traceSegments {
            switch segment {
                case .line(_, let end):
                    waypoints.append(
                        SC.Waypoint(position: SIMD3(end.x, end.y, z), motion: .linear, feedRate: settings.cutting.feedRate)
                    )
                case .arc(let center, let radius, _, let endAngle, let isCCW):
                    let endX = center.x + radius * cos(endAngle)
                    let endY = center.y + radius * sin(endAngle)
                    waypoints.append(
                        SC.Waypoint(position: SIMD3(endX, endY, z),
                                    motion: isCCW ? .arcCCW(center: center) : .arcCW(center: center),
                                    feedRate: settings.cutting.feedRate)
                    )
            }
        }

        if let lastPoint = waypoints.last?.position {
            waypoints.append(
                SC.Waypoint(position: SIMD3(lastPoint.x, lastPoint.y, settings.safeZ), motion: .rapid, feedRate: settings.cutting.feedRate)
            )
        }

        return waypoints
    }

    // MARK: - Step 2.2a: ring geometry

    /// Generates the concentric ring stack for `.offsetPattern` pocketing, geometry
    ///
    /// Rings are returned **outside-in** (boundary ring first, smallest ring last).
    ///
    /// Stepping stops as soon as a ring would collapse. Two collapse signals are
    /// checked, because the existing `offsetContour` only catches one of them:
    /// - `offsetContour` itself returns its input unchanged when an arc segment's
    ///   offset radius would go to zero or below (its documented "tool too big for
    ///   this feature" signal) -- caught here as `next == current`.
    /// - For straight-edge rings (e.g. a rectangle), no segment ever individually
    ///   "collapses" that way -- offsetting past the center just inverts the ring.
    ///   `offsetContour` doesn't yet detect that kind of self-intersection (it's
    ///   the documented limitation flagged for Track 4.3), so this checks the
    ///   ring's winding direction instead: a flip from the boundary's original
    ///   winding means the offset pushed through the ring's own center.
    ///
    /// - Parameter stepoverPercentage: Fraction (0.1-0.95) of `tool.diameter` used as the
    ///   center-to-center spacing between adjacent rings -- this comes from `CuttingData`
    ///   rather than the tool itself, since the same physical tool can be run at different
    ///   stepovers depending on material and job.
    func pocketRings(from orientedBoundary: [SC.Segment], tool: SC.ToolParams, stepoverPercentage: Double) -> [[SC.Segment]] {

        let firstRing = offsetContour(orientedBoundary,
                                      side: .inside,
                                      toolRadius: tool.diameter / 2.0,
                                      isClosed: true)
        guard !firstRing.isEmpty else {
            return []
        }

        var rings: [[SC.Segment]] = [firstRing]

        let stepover = stepoverPercentage * tool.diameter
        guard stepover > 1e-6 else {
            // No forward progress possible with a zero/negative stepover -- the
            // boundary ring is all we can offer.
            return rings
        }

        let winding = OffsetTools.isCCWWinding(firstRing)
        var current = firstRing

        // Safety cap: the full-collapse check and the winding-flip check below are
        // expected to end the loop first in every realistic case, but a cap keeps
        // a pathological input from spinning forever.
        let maxRings = 500
        while rings.count < maxRings {
            let next = offsetContour(current, side: .inside, toolRadius: stepover, isClosed: true)

            guard next != current else {
                // `offsetContour` only ever returns its input unchanged when every
                // one of its segments failed to offset -- a corner fillet running
                // out of radius on its own now degrades to a sharp corner instead
                // (see `offsetContour`), so this only fires when the tool no
                // longer fits *anywhere* on this ring.
                break
            }
            guard OffsetTools.isCCWWinding(next) == winding else {
                break // Straight-edge collapse: the ring inverted through its own center.
            }

            // An all-arc ring (a circle) never fails to offset or flips winding: past its
            // centre it just inverts into a growing circle, and the loop would only stop at
            // `maxRings` after seconds of pointless offsetting. An inward offset can only
            // shrink the ring, so a bigger bounding box (or a non-positive radius) means it
            // has collapsed.
            let currentBox = current.boundingBox, nextBox = next.boundingBox
            let grew = (nextBox.maxX - nextBox.minX) > (currentBox.maxX - currentBox.minX) + 1e-9
                || (nextBox.maxY - nextBox.minY) > (currentBox.maxY - currentBox.minY) + 1e-9
            let degenerateArc = next.contains { segment in
                if case .arc(_, let radius, _, _, _) = segment { return radius <= 1e-6 }
                return false
            }
            guard !grew, !degenerateArc else {
                break
            }

            rings.append(next)
            current = next
        }

        return rings
    }

    // MARK: - Concentric rings morphing from a circle to a rectangle

    /// Rings for an axis-aligned rectangular `wallRing`, ordered inside-out, that start as
    /// a perfect circle at the centre and end as the sharp rectangle:
    ///   1. Perfect circles, radius growing one `stepover` at a time until the circle
    ///      touches the long walls (for a square that already reaches the wall).
    ///   2. Stadium rings (semicircular ends, lengthening straight core) whose ends advance
    ///      one `stepover` at a time to the far walls.
    ///   3. Rounded-rectangle rings with the wall's full extents and a corner radius that
    ///      shrinks to zero, so the corners sharpen gradually.
    ///   4. The wall rectangle itself.
    /// Every ring starts at the middle of its bottom edge, so the links between rings are
    /// short vertical moves. Returns `nil` when `wallRing` isn't an axis-aligned rectangle.
    func roundedMorphRings(wallRing: [SC.Segment], toolRadius: Double, stepover: Double) -> [[SC.Segment]]? {
        guard wallRing.count == 4, stepover > 1e-6 else {
            return nil
        }
        for segment in wallRing {
            guard case .line(let a, let b) = segment, abs(a.x - b.x) < 1e-6 || abs(a.y - b.y) < 1e-6 else {
                return nil
            }
        }

        let box = wallRing.boundingBox
        let center = CGPoint(x: (box.minX + box.maxX) / 2, y: (box.minY + box.maxY) / 2)
        let halfWidth = (box.maxX - box.minX) / 2
        let halfHeight = (box.maxY - box.minY) / 2
        let h = min(halfWidth, halfHeight)
        guard h > 1e-6 else {
            return nil
        }
        let isWide = halfWidth >= halfHeight
        let coreHalfLength = abs(halfWidth - halfHeight)

        var rings: [[SC.Segment]] = []

        // 1. Perfect circles, smallest first: the helix-radius circle (reaches the centre),
        //    then one stepover bigger each time, the last (shorter step) touching the long walls.
        let radii = insideOutCircleRadii(maxRadius: h, toolRadius: toolRadius, stepover: stepover)
        for r in radii {
            rings.append(roundedRectangleRing(center: center, halfWidth: r, halfHeight: r, cornerRadius: r))
        }

        // Past that the circle can't grow sideways, so its ends keep advancing along the
        // long axis one stepover at a time (a stadium with a lengthening straight core)
        // until the ends reach the far walls.
        var advance = stepover
        while advance < coreHalfLength - 1e-6 {
            rings.append(roundedRectangleRing(center: center,
                                              halfWidth: isWide ? h + advance : h,
                                              halfHeight: isWide ? h : h + advance,
                                              cornerRadius: h))
            advance += stepover
        }
        if coreHalfLength > 1e-6 {
            rings.append(roundedRectangleRing(center: center,
                                              halfWidth: halfWidth,
                                              halfHeight: halfHeight,
                                              cornerRadius: h))
        }

        // 2. Corners sharpening. A corner of radius r sits r * (sqrt(2) - 1) from the
        // sharp corner along the diagonal, so this step keeps the diagonal gap at `stepover`.
        let cornerStep = stepover / (2.0.squareRoot() - 1.0)
        var cornerRadius = h - cornerStep
        while cornerRadius > 1e-6 {
            rings.append(roundedRectangleRing(center: center,
                                              halfWidth: halfWidth,
                                              halfHeight: halfHeight,
                                              cornerRadius: cornerRadius))
            cornerRadius -= cornerStep
        }

        // 3. The wall rectangle.
        rings.append(roundedRectangleRing(center: center,
                                          halfWidth: halfWidth,
                                          halfHeight: halfHeight,
                                          cornerRadius: 0))

        // Built counter-clockwise; match the wall ring's winding (climb/conventional).
        if !OffsetTools.isCCWWinding(wallRing) {
            rings = rings.map { ring in ring.reversed().map { $0.reversed } }
        }
        return rings
    }

    /// A closed counter-clockwise rounded rectangle starting at the middle of its bottom edge.
    private func roundedRectangleRing(center c: CGPoint, halfWidth a: Double, halfHeight b: Double, cornerRadius: Double) -> [SC.Segment] {
        let r = min(max(cornerRadius, 0), min(a, b))
        var segments: [SC.Segment] = []

        func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
            if hypot(x1 - x0, y1 - y0) > 1e-9 {
                segments.append(.line(start: CGPoint(x: x0, y: y0), end: CGPoint(x: x1, y: y1)))
            }
        }
        func arc(_ cx: Double, _ cy: Double, _ startDegrees: Double) {
            if r > 1e-9 {
                segments.append(.arc(center: CGPoint(x: cx, y: cy),
                                     radius: r,
                                     startAngle: startDegrees * .pi / 180,
                                     endAngle: (startDegrees + 90) * .pi / 180,
                                     isCCW: true))
            }
        }

        line(c.x, c.y - b, c.x + a - r, c.y - b)
        arc(c.x + a - r, c.y - b + r, -90)
        line(c.x + a, c.y - b + r, c.x + a, c.y + b - r)
        arc(c.x + a - r, c.y + b - r, 0)
        line(c.x + a - r, c.y + b, c.x - a + r, c.y + b)
        arc(c.x - a + r, c.y + b - r, 90)
        line(c.x - a, c.y + b - r, c.x - a, c.y - b + r)
        arc(c.x - a + r, c.y - b + r, 180)
        line(c.x - a + r, c.y - b, c.x, c.y - b)

        return segments
    }

    func midpoint(of segment: SC.Segment) -> CGPoint {
        let length = segment.pathLength
        return pointAlong(segment: segment, distance: length / 2, length: length)
    }

    /// Even-odd test of `point` against the closed `loop`.
    private func pointInside(_ point: CGPoint, loop: [SC.Segment]) -> Bool {
        horizontalIntersections(y: point.y, with: loop).filter { $0 > point.x }.count % 2 == 1
    }

    /// Shortest distance from `point` to `segment`.
    func distance(from point: CGPoint, to segment: SC.Segment) -> Double {
        switch segment {
            case .line(let a, let b):
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                let t = len2 > 1e-18 ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / len2, 0), 1) : 0
                return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))

            case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                let angle = atan2(point.y - center.y, point.x - center.x)
                if EngineTools.angleWithinSweep(angle, start: startAngle, end: endAngle, isCCW: isCCW) {
                    return abs(hypot(point.x - center.x, point.y - center.y) - radius)
                }
                let s = segment.startPoint, e = segment.endPoint
                return min(hypot(point.x - s.x, point.y - s.y), hypot(point.x - e.x, point.y - e.y))
        }
    }

    // MARK: - Step 2.2b: chaining rings into one continuous pass

    /// Chains a ring stack (ordered outside-in, as `pocketRings` produces them)
    /// into one flat segment list, inserting a straight connecting move between
    /// the end of each ring and the start of the next. Generic enough that
    /// `rasterScanlines`' row list reuses it too -- a stack of segment groups
    /// needing connecting transitions is the same shape either way.
    ///
    /// Each ring is already a closed loop on its own (its last segment's end
    /// point coincides with its first segment's start point), so the only new
    /// geometry needed here is that one connecting move per ring transition --
    /// a lateral step of exactly `stepover` into the band that ring just opened
    /// up, never a move into an untouched part of the pocket.
    func chainedRingSegments(_ rings: [[SC.Segment]]) -> [SC.Segment] {
        var chained: [SC.Segment] = []

        for ring in rings {
            guard !ring.isEmpty else {
                continue
            }

            if let previousEnd = chained.last?.endPoint {
                let ringStart = ring[0].startPoint
                if hypot(ringStart.x - previousEnd.x, ringStart.y - previousEnd.y) > 1e-6 {
                    chained.append(.line(start: previousEnd, end: ringStart))
                }
            }

            chained.append(contentsOf: ring)
        }

        return chained
    }

    // MARK: - Step 1B.1: spiral pocket

    /// Whether `boundary` has the single well-defined center a continuous spiral needs
    /// to interpolate around -- true only when every segment is an arc sharing the same
    /// center and radius, i.e. a full circle.
    private func isSpiralEligible(_ boundary: [SC.Segment]) -> Bool {
        guard case .arc(let center, let radius, _, _, _) = boundary.first else {
            return false
        }
        return boundary.allSatisfy { segment in
            guard case .arc(let c, let r, _, _, _) = segment else {
                return false
            }
            return hypot(c.x - center.x, c.y - center.y) < 1e-6 && abs(r - radius) < 1e-6
        }
    }

    /// Turns a concentric ring stack (as `pocketRings` produces, outside-in) into one
    /// continuous spiral: one full turn per ring-to-ring transition, radius interpolating
    /// linearly from that ring's radius to the next ring's radius over the turn, so the
    /// path never closes on itself the way `chainedRingSegments`' discrete
    /// rings-plus-transitions does. The opening turn holds at one end's radius, and the
    /// final turn holds at the other end's radius, rather than interpolating --
    /// symmetric bookends, each fully closing a true circle: the opening one so that
    /// ring actually gets swept all the way round instead of the path peeling away from
    /// it after only a single instant at the start angle (an interpolating first turn
    /// only touches that radius once, at step 0 -- by the time it's back around to that
    /// angle, one full stepover later, up to a stepover's width of that band never had
    /// the cutter reach it), and the closing one for the "final pass" the `.spiral`
    /// case's own doc comment describes as the one place the path does close.
    ///
    /// As of Step 1B.1b, which end is which is `direction`'s call: `.outsideIn` (the
    /// original Step 1B.1 behavior) opens on the outermost (wall) ring and closes on the
    /// innermost, fully closing out the pocket floor at depth; `.insideOut` reverses the
    /// ring order before doing anything else, so the exact same logic below opens on the
    /// innermost ring and closes on a single, uninterrupted final pass around the wall.
    /// Reversing the ring order up front (rather than branching the bookend logic
    /// itself) is also what makes `.insideOut`'s entry come out correct for free: the
    /// caller's first plunge point is always this function's first waypoint, and once
    /// the rings are reversed that's already the innermost ring's own start point --
    /// exactly where `.insideOut` needs to plunge, per the `.spiral` case's own doc
    /// comment, without any separate "find the innermost ring" logic here.
    ///
    /// `SC.Segment` has no primitive for an arc of continuously-changing radius, so the
    /// spiral is approximated as a polyline of short `.line` chords -- the same kind of
    /// tessellation trade-off `helixEntryWaypoints` already makes for its own circular
    /// entry move, just at a finer resolution here (every 5 degrees rather than every
    /// 45): this is the whole cut, not a short entry hop clear of any wall, so visible
    /// faceting on the pocket floor matters more.
    ///
    /// Only called once `isSpiralEligible` has confirmed every ring shares one true
    /// center -- `rings` themselves are trusted to be concentric arcs here rather than
    /// re-checked.
    private func spiralSegments(from rings: [[SC.Segment]], direction: SC.SpiralDirection) -> [SC.Segment] {
        let orderedRings: [[SC.Segment]] = direction == .insideOut ? Array(rings.reversed()) : rings

        // Not converted to `throws` in Step 6.7b: `buildPocketToolpath`'s `.spiral` case
        // only ever calls this after `pocketRings` has already come back non-empty (its
        // own empty result throws `SC.Error.geometryCollapsed`, Step 6.7a) *and*
        // `isSpiralEligible(oriented)` has confirmed the boundary that `rings` was built
        // from is entirely `.arc` segments sharing one center/radius -- and every ring
        // `pocketRings` produces is itself a re-offset of that same boundary, so it stays
        // all-arc too. This guard is therefore unreachable through the normal call chain,
        // same reasoning as `pocketRings`' own `firstRing` guard above: kept so a direct
        // caller handed an empty or non-arc ring stack (bypassing `buildPocketToolpath`'s
        // own validation) gets an empty spiral back rather than crashing on
        // `orderedRings.first!.first!`.
        guard case .arc(let center, let startRadius, let startAngle, _, let isCCW) = orderedRings.first?.first else {
            return []
        }

        let radii: [Double] = orderedRings.map { ring -> Double in
            guard case .arc(_, let r, _, _, _) = ring.first else {
                return startRadius // unreachable once `isSpiralEligible` has passed.
            }
            return r
        }

        let stepsPerTurn = 72
        // Bookend turns (hold at the outer wall radius, hold at the inner closing radius)
        // plus one interpolating turn per ring-to-ring transition.
        let turnCount = radii.count + 1
        let lastTurnIndex = turnCount - 1
        let totalSteps = turnCount * stepsPerTurn
        let angleStep = (2 * Double.pi / Double(stepsPerTurn)) * (isCCW ? 1.0 : -1.0)

        func point(atStep step: Int) -> CGPoint {
            let turnIndex = min(step / stepsPerTurn, lastTurnIndex)
            let angle = startAngle + angleStep * Double(step)

            let radius: Double
            if turnIndex == 0 {
                radius = radii[0] // opening turn: constant, at `orderedRings`' first radius.
            } else if turnIndex == lastTurnIndex {
                radius = radii[radii.count - 1] // final closing turn: constant, at `orderedRings`' last radius.
            } else {
                let stepWithinTurn = step % stepsPerTurn
                let t = Double(stepWithinTurn) / Double(stepsPerTurn)
                radius = radii[turnIndex - 1] + (radii[turnIndex] - radii[turnIndex - 1]) * t
            }

            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }

        var segments: [SC.Segment] = []
        var previousPoint = point(atStep: 0)

        for step in 1...totalSteps {
            let nextPoint = point(atStep: step)
            segments.append(.line(start: previousPoint, end: nextPoint))
            previousPoint = nextPoint
        }

        return segments
    }

    // MARK: - Raster wall finishing

    /// Rotates a closed, contiguous loop so it starts at `point` (which should lie on the
    /// loop), splitting the segment that contains it. Returns `loop` unchanged when `point`
    /// isn't on it.
    func rotatedLoop(_ loop: [SC.Segment], startingAt point: CGPoint) -> [SC.Segment] {
        let tolerance = 1e-4
        var best: (index: Int, distance: Double)?

        for (index, segment) in loop.enumerated() {
            let distance: Double
            switch segment {
                case .line(let a, let b):
                    let dx = b.x - a.x, dy = b.y - a.y
                    let len2 = dx * dx + dy * dy
                    let t = len2 > 1e-18 ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / len2, 0), 1) : 0
                    distance = hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))

                case .arc(let c, let r, let startAngle, let endAngle, let isCCW):
                    let angle = atan2(point.y - c.y, point.x - c.x)
                    if EngineTools.angleWithinSweep(angle, start: startAngle, end: endAngle, isCCW: isCCW) {
                        distance = abs(hypot(point.x - c.x, point.y - c.y) - r)
                    } else {
                        distance = .greatestFiniteMagnitude
                    }
            }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }

        guard let found = best, found.distance < tolerance else {
            return loop
        }

        let segment = loop[found.index]
        var head: [SC.Segment] = []   // from `point` to the end of the split segment
        var tail: [SC.Segment] = []   // from the start of the split segment to `point`

        switch segment {
            case .line(let a, let b):
                if hypot(point.x - b.x, point.y - b.y) > 1e-6 {
                    head.append(.line(start: point, end: b))
                }
                if hypot(point.x - a.x, point.y - a.y) > 1e-6 {
                    tail.append(.line(start: a, end: point))
                }

            case .arc(let c, let r, let startAngle, let endAngle, let isCCW):
                let angle: Double = atan2(point.y - c.y, point.x - c.x)
                let p = CGPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
                if hypot(p.x - segment.endPoint.x, p.y - segment.endPoint.y) > 1e-6 {
                    head.append(.arc(center: c, radius: r, startAngle: angle, endAngle: endAngle, isCCW: isCCW))
                }
                if hypot(p.x - segment.startPoint.x, p.y - segment.startPoint.y) > 1e-6 {
                    tail.append(.arc(center: c, radius: r, startAngle: startAngle, endAngle: angle, isCCW: isCCW))
                }
        }

        let after = Array(loop[(found.index + 1)...])
        let before = Array(loop[..<found.index])
        return head + after + before + tail
    }

    // MARK: - Raster scanline geometry

    /// Generates the raster scanline geometry for `.raster` pocketing: parallel
    /// horizontal cuts spaced `stepover` apart, each clipped to where it crosses
    /// `boundary` -- geometry only, no waypoints yet (that's `chainedRingSegments`
    /// + `buildWaypoints`, same as the ring stack).
    ///
    /// Rows run bottom-to-top and alternate direction (boustrophedon) so the
    /// connecting move `chainedRingSegments` inserts between rows is always a
    /// short vertical step rather than a long retrace across the pocket. Which
    /// way the *first* row travels is `direction`'s only say here -- `.climb`
    /// starts left-to-right, `.conventional` starts right-to-left -- since
    /// there's no wall cut in a pure raster fill for climb/conventional to
    /// otherwise apply to.
    ///
    /// The last row is snapped exactly onto `boundary`'s top edge rather than
    /// landing short or overshooting, the same fencepost convention
    /// `calculateZPasses` uses for Z stepdown.
    ///
    /// - Note: assumes exactly one cut span per row -- correct for the closed,
    ///   island-free boundaries currently in scope (see the islands note on
    ///   Track 1 in the roadmap). A concave boundary that re-enters the same
    ///   row more than once would need per-span chaining this doesn't attempt
    ///   yet; such a row is skipped rather than cut wrong.
    func rasterScanlines(within boundary: [SC.Segment], stepover: Double, direction: SC.CutDirection) -> [[SC.Segment]] {
        // Not converted to `throws` in Step 6.7b, same reasoning as `pocketRings`' own
        // top guard: `buildPocketToolpath`'s `.raster` case only ever calls this with a
        // `boundary` already confirmed non-empty (its own `wallOffset.isEmpty` guard
        // throws `SC.Error.geometryCollapsed` first, Step 6.7a), and `stepover` is
        // `stepoverPercentage * tool.diameter` where `stepoverPercentage` is documented
        // (see `pocketRings`) to range 0.1-0.95 of a positive tool diameter -- so
        // `stepover > 1e-6` always holds through the normal call chain too. Both halves
        // of this guard are therefore unreachable in practice, kept only so a direct
        // caller handed a degenerate boundary or stepover gets an empty row list back
        // instead of dividing by (or bounding-boxing) nothing below.
        guard stepover > 1e-6, !boundary.isEmpty else {
            return []
        }

        let box = boundary.boundingBox
        let span = box.maxY - box.minY
        // Unlike the guard above, this one *is* reachable through the normal call
        // chain: `wallOffset` being non-empty doesn't guarantee it has any Y extent --
        // an extremely thin slot can offset down to a sliver whose bounding box
        // collapses to a single row's height. That's a genuine "the algorithm had
        // nothing to build from" case, not a bad-input one (the input already passed
        // `buildPocketToolpath`'s own validation), so it's the same
        // `SC.Error.geometryCollapsed` situation `pocketRings`' own mid-stack collapse
        // represents -- and just like that one, the translation happens at the call
        // site: `buildPocketToolpath`'s `guard !rows.isEmpty else { throw
        // SC.Error.geometryCollapsed }` (Step 6.7a) already catches this the moment it
        // propagates up as an empty `rows` array, so this function itself stays
        // non-throwing rather than duplicating that translation here.
        guard span > 1e-9 else {
            return []
        }

        // Same whole-number snapping `calculateZPasses` uses: a span that divides
        // evenly by `stepover` shouldn't gain a spurious extra row from float drift.
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
            let y = (i == rowCount - 1) ? box.maxY : box.minY + stepover * Double(i)
            var xs = horizontalIntersections(y: y, with: boundary).sorted()

            // Two adjacent segments that share a vertex exactly on this row (e.g. a
            // straight edge ending exactly where an arc begins) each independently
            // register a crossing at that shared point -- collapse those into one
            // logical crossing rather than letting them masquerade as a second span.
            var deduped: [Double] = []
            for x in xs {
                if let last = deduped.last, abs(x - last) < 1e-6 {
                    continue
                }
                deduped.append(x)
            }
            xs = deduped

            // Exactly 2 crossings is the single-span case this function supports (see
            // the doc comment above). 0 or 1 means the row misses the boundary or only
            // grazes it. More than 2 means the row re-enters the boundary more than
            // once -- a concave row -- which needs per-span chaining this doesn't
            // attempt yet, so it's skipped rather than cut wrong (bridging a gap that
            // isn't actually inside the pocket). Step 6.7b judgment call: this is
            // firmly "empty is a valid result," not "empty means something broke" --
            // a single skipped row among many is an accepted, documented limitation of
            // this raster implementation (see the function's own doc comment), not a
            // failure of the input or the algorithm as a whole, so it stays a silent
            // `continue` rather than surfacing an error for a row that was never
            // promised full coverage in the first place. `rasterScanlines` only throws
            // (via its caller, `buildPocketToolpath`'s Step 6.7a guard) when *every*
            // row is skipped this way and `rows` comes back completely empty.
            guard xs.count == 2, let x0 = xs.first, let x1 = xs.last else {
                continue
            }

            let row: SC.Segment = leftToRight
                ? .line(start: CGPoint(x: x0, y: y), end: CGPoint(x: x1, y: y))
                : .line(start: CGPoint(x: x1, y: y), end: CGPoint(x: x0, y: y))

            rows.append([row])
            leftToRight.toggle()
        }

        return rows
    }

    /// Every x where the infinite horizontal line `y` crosses `segments`, bounded to
    /// each segment's own extent (its `[0,1]` parametric range for a line, its angular
    /// sweep for an arc) -- unlike `SCEngine+Offset.swift`'s intersection helpers, which
    /// treat lines as infinite and arcs as full circles because they only need the point
    /// nearest a known vertex. A scanline clip has no such vertex to anchor on, so it
    /// needs the true bounded crossings.
    private func horizontalIntersections(y: Double, with segments: [SC.Segment]) -> [Double] {
        var xs: [Double] = []

        for segment in segments {
            switch segment {
                case .line(let start, let end):
                    let dy = end.y - start.y
                    guard abs(dy) > 1e-9 else {
                        continue // Horizontal edge: coincides with at most a whole row, no single crossing.
                    }
                    let t = (y - start.y) / dy
                    guard t >= -1e-9, t <= 1 + 1e-9 else {
                        continue
                    }
                    let clampedT = min(max(t, 0), 1)
                    xs.append(start.x + clampedT * (end.x - start.x))

                case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                    let dy = y - center.y
                    guard abs(dy) <= radius else {
                        continue
                    }
                    let dx = (radius * radius - dy * dy).squareRoot()
                    let candidateXs = dx > 1e-9 ? [center.x - dx, center.x + dx] : [center.x]

                    for cx in candidateXs {
                        let angle = atan2(y - center.y, cx - center.x)
                        if EngineTools.angleWithinSweep(angle, start: startAngle, end: endAngle, isCCW: isCCW) {
                            xs.append(cx)
                        }
                    }
            }
        }

        return xs
    }

    // MARK: - Trochoidal pocket

    /// Bounces the cutter along `ring` (one ring in `pocketRings`'s own
    /// concentric stack, ordered outside-in) the same one-sided,
    /// wall-anchored way `.slotting`'s own `openEndedTrochoidalSegments`
    /// bounces along an open centerline -- adapted here for a *closed* ring
    /// rather than an open, mouth-to-mouth centerline. Per cycle, in order:
    ///   a) The tool is already sitting on `ring`'s own path (the real wall
    ///      for this band -- either the pocket's own true wall, for the
    ///      outermost ring, or the position the *previous* cycle's own bounce
    ///      already returned to).
    ///   b) A semicircle -- radius `bandWidth / 2`, bulging `bandWidth / 2`
    ///      forward into fresh material at its midpoint -- sweeps inward
    ///      (never outward) to a virtual wall exactly `bandWidth` in from
    ///      `ring`'s own path: the position the *next* ring inward will
    ///      itself occupy.
    ///   c) A straight line moves back to `ring`'s own path, at this same
    ///      position along it (not yet advanced).
    ///   d) A straight line advances forward along `ring` by
    ///      `radialEngagement * tool.diameter / 2` (`radialEngagement`
    ///      clamped to `0...1`), ready for the next cycle's own semicircle
    ///      (step b again) -- wrapping all the way around the closed ring,
    ///      rather than stopping at a fixed end the way an open centerline
    ///      does.
    ///
    /// Deliberately one-sided (inward only), unlike an earlier version of
    /// this idea that bounced symmetrically `±loopRadius` off a single path:
    /// `ring` is already the real, correctly-inset wall for this band, so
    /// bouncing to its *outward* side would push the tool back out past
    /// material that's already been (or is about to be) cleared -- once the
    /// tool's own radius is added on top of that outward excursion, the
    /// cutting edge overshoots the pocket's true wall entirely. Staying
    /// strictly within `[0, bandWidth]` of `ring`'s own path (inclusive)
    /// keeps every cycle bounded between this ring and the very next one,
    /// never beyond either -- the same guarantee `.slotting`'s own bounce
    /// gets from both its walls being real, just enforced here by only ever
    /// bouncing toward the one side that's actually safe.
    ///
    /// `ring`'s own winding (guaranteed consistent by `orientedForDirection`'s
    /// `side: .inside` contract, upstream in `buildPocketToolpath`)
    /// determines which side of the local normal actually points into the
    /// pocket's interior: a CCW-wound closed curve has its interior on the
    /// left of travel (the `normal` as defined below); a CW-wound curve has
    /// it on the right.
    func ringTrochoidalSegments(from ring: [SC.Segment],
                                tool: SC.ToolParams,
                                bandWidth: Double,
                                radialEngagement: Double) -> [SC.Segment] {

        // Not converted to `throws` in Step 6.7b: `buildPocketToolpath`'s `.trochoidal`
        // case only ever calls this once per ring in `pocketRings`' own non-empty
        // stack (empty guarded off already, both here and via Step 6.7a's
        // `geometryCollapsed` throw at the call site), so an empty `ring` here is
        // unreachable through the normal call chain -- kept only so a direct caller
        // handed an empty ring gets an empty bounce path back rather than crashing on
        // `ring`'s own path-length/geometry calculations below.
        guard !ring.isEmpty else {
            return []
        }
        guard bandWidth > 1e-6 else {
            // No band left to bounce within -- just trace the ring itself.
            return ring
        }

        // The forward pitch per cycle: a fraction (clamped to 0...1) of the
        // tool's own radius, same convention `.slotting`'s own
        // `openEndedTrochoidalSegments` uses.
        let clampedEngagement = min(max(radialEngagement, 0), 1)
        let pitch = max(clampedEngagement, 1e-3) * (tool.diameter / 2.0)
        // Unreachable in practice, same reasoning as the `ring.isEmpty` guard above:
        // `clampedEngagement` is floored at `1e-3` and `tool.diameter` is always a
        // positive, real tool size, so `pitch` can only fail this check for a
        // pathologically small (sub-micron) tool -- kept as a guard rather than an
        // assumption so a degenerate tool still returns an empty path instead of
        // looping on a near-zero `pitch` below.
        guard pitch > 1e-6 else {
            return []
        }

        let totalLength = ring.pathLength
        // Unlike the two guards above, this one is (in principle) reachable: `ring`
        // being non-empty doesn't guarantee it has positive path length -- a
        // degenerate ring whose segments all collapse to the same point would pass
        // `!ring.isEmpty` but fail here. Same `SC.Error.geometryCollapsed` situation
        // `rasterScanlines`' own `span > 1e-9` guard represents: the input already
        // passed `buildPocketToolpath`'s own validation, so this is the algorithm
        // finding nothing to build from, not bad input. `buildPocketToolpath`'s
        // `.trochoidal` case doesn't throw per-ring on this, though -- it treats one
        // degenerate ring among several the same way `rasterScanlines`' per-row skip
        // treats one degenerate row (see that guard's own Step 6.7b note): a
        // `continue` past this one band rather than aborting the whole pocket, since
        // the other rings' bands are still perfectly good geometry. Only if *every*
        // ring skips this way does the resulting empty `chained` trip
        // `buildPocketToolpath`'s final `toolpathSegments.isEmpty` throw.
        guard totalLength > 1e-9 else {
            return []
        }

        // A closed ring wraps all the way back around to its own start -- no
        // fencepost "final bite pinned exactly at the end" is needed the way
        // an open centerline needs one (there's no true end to land exactly
        // on), so cycles are simply spaced every `pitch` around the full
        // circumference. The caller's own connecting move (mirroring
        // `chainedRingSegments`'s convention) closes the gap from this
        // ring's own last bite to the next ring's first.
        let cycleCount = max(1, Int((totalLength / pitch).rounded(.up)))

        let isCCW = OffsetTools.isCCWWinding(ring)
        let inwardSign: Double = isCCW ? 1.0 : -1.0
        let halfBand = bandWidth / 2.0
        let stepsPerSemicircle = 36 // same 5-degrees/step resolution `spiralSegments` uses.

        var segments: [SC.Segment] = []
        var previousWallPoint: CGPoint?

        for i in 0..<cycleCount {
            let distance = pitch * Double(i)
            let origin = point(alongPath: ring, distance: distance, totalLength: totalLength)
            let travelDirection = tangent(alongPath: ring, distance: distance, totalLength: totalLength)
            let normal = CGPoint(x: -travelDirection.y, y: travelDirection.x)

            func local(_ u: Double, _ v: Double) -> CGPoint {
                CGPoint(x: origin.x + u * travelDirection.x + v * normal.x,
                        y: origin.y + u * travelDirection.y + v * normal.y)
            }

            let wallPoint = local(0, 0)

            // d) Advance forward along the ring from the previous cycle's
            // own closing point to this cycle's wall point.
            if let previousWallPoint, hypot(wallPoint.x - previousWallPoint.x, wallPoint.y - previousWallPoint.y) > 1e-6 {
                segments.append(.line(start: previousWallPoint, end: wallPoint))
            }

            // b) The semicircle itself: starts on the ring (v=0), bulges
            // `halfBand` forward at its midpoint, and finishes at the
            // virtual wall `bandWidth` inward (v = inwardSign * bandWidth) --
            // never past it, and never outward past v=0.
            var previousPoint = wallPoint
            for step in 1...stepsPerSemicircle {
                let t = Double(step) / Double(stepsPerSemicircle)
                let angle = -Double.pi / 2 + Double.pi * t
                let u = halfBand * cos(angle)
                let v = inwardSign * (halfBand * sin(angle) + halfBand)
                let nextPoint = local(u, v)
                segments.append(.line(start: previousPoint, end: nextPoint))
                previousPoint = nextPoint
            }

            // c) Straight line back to the ring's own path, at this same
            // position (not yet advanced -- that's step d, above, on the
            // next cycle).
            segments.append(.line(start: previousPoint, end: wallPoint))
            previousWallPoint = wallPoint
        }

        return segments
    }

    /// Walks `segments` (assumed contiguous, as `orientedForDirection`'s output
    /// always is) `distance` along its total arc length and returns the point there --
    /// the same "walk the chain by cumulative length" approach
    /// `SCEngine+Contour.swift`'s `tracedWaypoints` already uses for holding-tab
    /// spans, just returning a point instead of a Z clamp.
    ///
    /// Not `private` -- `SCEngine+Slotting.swift`'s own
    /// `openEndedTrochoidalSegments` reuses this same "walk the chain" logic for
    /// its wall-to-wall bites along an open-ended slot's centerline.
    func point(alongPath segments: [SC.Segment], distance: Double, totalLength: Double) -> CGPoint {
        guard let firstSegment = segments.first else {
            return .zero
        }

        let clamped = min(max(distance, 0), totalLength)
        var cumulative = 0.0

        for (index, segment) in segments.enumerated() {
            let length = segment.pathLength
            let isLast = index == segments.count - 1
            if clamped <= cumulative + length + 1e-9 || isLast {
                let remaining = min(max(clamped - cumulative, 0), length)
                return pointAlong(segment: segment, distance: remaining, length: length)
            }
            cumulative += length
        }

        return firstSegment.startPoint
    }

    /// The point `distance` along a single segment's own length, parameterizing a
    /// line linearly and an arc by its angular sweep.
    private func pointAlong(segment: SC.Segment, distance: Double, length: Double) -> CGPoint {
        guard length > 1e-9 else {
            return segment.startPoint
        }
        let t = distance / length

        switch segment {
            case .line(let start, let end):
                return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)

            case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                let sweep = SC.Segment.sweepAngle(start: startAngle, end: endAngle, isCCW: isCCW)
                let angle = startAngle + (isCCW ? 1.0 : -1.0) * sweep * t
                return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
    }

    /// Walks `segments` (assumed contiguous, as `orientedForDirection`'s output
    /// always is) `distance` along its total arc length and returns the unit
    /// tangent (direction of travel) there -- `trochoidalSegments`'s own
    /// counterpart to `point(alongPath:distance:totalLength:)`, needed to build
    /// the local forward/lateral frame each of its bites bounces within.
    ///
    /// Not `private` -- see `point(alongPath:distance:totalLength:)`'s own note
    /// above.
    func tangent(alongPath segments: [SC.Segment], distance: Double, totalLength: Double) -> CGPoint {
        guard let firstSegment = segments.first else {
            return CGPoint(x: 1, y: 0)
        }

        let clamped = min(max(distance, 0), totalLength)
        var cumulative = 0.0

        for (index, segment) in segments.enumerated() {
            let length = segment.pathLength
            let isLast = index == segments.count - 1
            if clamped <= cumulative + length + 1e-9 || isLast {
                let remaining = min(max(clamped - cumulative, 0), length)
                return tangentAlong(segment: segment, distance: remaining, length: length)
            }
            cumulative += length
        }

        return direction(of: firstSegment, atEnd: false)
    }

    /// The unit tangent `distance` along a single segment's own length --
    /// `pointAlong`'s counterpart for direction rather than position.
    private func tangentAlong(segment: SC.Segment, distance: Double, length: Double) -> CGPoint {
        guard length > 1e-9 else {
            return direction(of: segment, atEnd: false)
        }

        switch segment {
            case .line(let start, let end):
                let dx = end.x - start.x, dy = end.y - start.y
                let len = hypot(dx, dy)
                guard len > 1e-9 else {
                    return CGPoint(x: 1, y: 0)
                }
                return CGPoint(x: dx / len, y: dy / len)

            case .arc(_, _, let startAngle, let endAngle, let isCCW):
                let t = distance / length
                let sweep = SC.Segment.sweepAngle(start: startAngle, end: endAngle, isCCW: isCCW)
                let angle = startAngle + (isCCW ? 1.0 : -1.0) * sweep * t
                let radialX = cos(angle), radialY = sin(angle)
                return isCCW ? CGPoint(x: -radialY, y: radialX) : CGPoint(x: radialY, y: -radialX)
        }
    }
}
