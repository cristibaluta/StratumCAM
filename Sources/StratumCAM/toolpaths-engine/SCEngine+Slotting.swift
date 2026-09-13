//
//  SCEngine+Slotting.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation
import CoreGraphics
import SwiftDXF

extension SCEngine {

    /// Builds the `.slotting` toolpath: follows the contour's centerline directly at
    /// cutter-center, no tool-radius offset (see `CutSide.onContour`'s own doc
    /// comment, which describes exactly this "slotting grooves" case -- a slot cuts
    /// full width on the curve itself rather than compensating to one side of it the
    /// way `.contour` does). `entry` (plunge/ramp/helix) is wired into the first
    /// pass's start point as of Step 2B.2, reusing the same `rampWaypoints`/
    /// `helixEntryWaypoints` machinery `.contour`/`.pocket` already use -- see
    /// `buildSlottingWaypoints` below.
    ///
    /// As of Step 2B.2, `depthPerPass` is the Z stepdown increment down to
    /// `settings.targetDepth` -- the same `calculateZPasses` reuse `.contour`/
    /// `.pocket` already do for their own `settings.cutting.stepdown`, just fed
    /// `depthPerPass` instead, since slotting's per-pass depth is the operation's
    /// own parameter rather than a shared machine-wide cutting setting.
    func buildSlottingToolpath(for contour: SC.Contour,
                               tool: SC.ToolParams,
                               settings: SC.MachineSettings,
                               depthPerPass: Double,
                               entry: SC.EntryStrategy,
                               operation: SC.MachiningOperation) -> SC.OutputToolpath? {

        let segments = linearize(contour: contour)
        guard let firstSegment = segments.first else {
            return nil
        }

        let zDepths = calculateZPasses(targetDepth: settings.targetDepth, stepdown: depthPerPass)

        var passes: [SC.ToolpathPass] = []
        var previousZ = 0.0 // top of stock -- pass 0 ramps/helixes down from here, same convention `.contour`/`.pocket` use.
        for (i, z) in zDepths.enumerated() {
            let waypoints = buildSlottingWaypoints(for: segments,
                                                   firstSegment: firstSegment,
                                                   atZ: z,
                                                   previousZ: previousZ,
                                                   settings: settings,
                                                   entry: entry)
            passes.append(SC.ToolpathPass(passIndex: i, depthZ: z, waypoints: waypoints))
            previousZ = z
        }

        return SC.OutputToolpath(operation: operation, tool: tool, settings: settings, passes: passes)
    }

    // MARK: - Slotting entry

    /// Wraps `segments` (the contour's own centerline, untouched by any offset) with
    /// an entry move honoring `entry`, then traces the geometry and retracts -- same
    /// three-phase shape as `.pocket`'s `buildPocketWaypoints`, just without the
    /// separate wall-boundary parameter pocketing needs for its helix's signed-offset
    /// calculation: slotting has no wall to stay clear of on either side, so `side` is
    /// always passed as `.onContour` below, resolving `helixEntryWaypoints`' internal
    /// `offsetDistance` call to a zero offset -- the helix circles centered exactly on
    /// the slot's own centerline, cutting material symmetrically on both sides as it
    /// descends, matching how the straight trace itself already cuts.
    ///
    /// `.plunge` is exactly the existing straight-down wrapper (`buildWaypoints`),
    /// same as `.pocket`'s and `.contour`'s own plunge entry -- always retracts to
    /// safeZ and re-plunges fresh on every pass rather than reading `previousZ`.
    /// `.ramp` and `.helix` only cover this pass's fresh stepdown, from `previousZ`
    /// (the depth the previous pass already reached) down to `z` -- the first pass's
    /// `previousZ` is `0` (top of stock), matching `.contour`'s/`.pocket`'s own
    /// first-pass behavior.
    private func buildSlottingWaypoints(for segments: [SC.Segment],
                                        firstSegment: SC.Segment,
                                        atZ z: Double,
                                        previousZ: Double,
                                        settings: SC.MachineSettings,
                                        entry: SC.EntryStrategy) -> [SC.Waypoint] {

        guard entry != .plunge else {
            return buildWaypoints(for: segments, atZ: z, settings: settings)
        }

        let startPoint = startPointOf(segment: firstSegment)
        let startTangent = direction(of: firstSegment, atEnd: false)

        var waypoints: [SC.Waypoint] = [
            SC.Waypoint(position: SIMD3(startPoint.x, startPoint.y, settings.safeZ),
                        motion: .rapid,
                        feedRate: settings.cutting.feedRate)
        ]

        switch entry {
            case .plunge:
                break // Handled above via `buildWaypoints`.

            case .ramp(let angleDegrees):
                waypoints.append(
                    contentsOf: rampWaypoints(firstSegment: firstSegment,
                                              angleDegrees: angleDegrees,
                                              fromZ: previousZ,
                                              toZ: z,
                                              settings: settings)
                )

            case .helix(let radius, let angleDegrees):
                waypoints.append(
                    contentsOf: helixEntryWaypoints(contourStart: startPoint,
                                                    startTangent: startTangent,
                                                    side: .onContour,
                                                    segments: segments,
                                                    firstSegment: firstSegment,
                                                    radius: radius,
                                                    angleDegrees: angleDegrees,
                                                    fromZ: previousZ,
                                                    toZ: z,
                                                    settings: settings)
                )
        }

        // Trace the centerline itself -- mirrors `buildWaypoints`' own trace step.
        for segment in segments {
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

    // MARK: - Slot boundary recognition (rectangle -> centerline)

    /// `buildSlottingToolpath` above (and `.slotting` generally) only ever knows how
    /// to cut a slot exactly `tool.diameter` wide, traced along whatever centerline
    /// it's handed directly -- it has no notion of a wall to stay off of, because
    /// there isn't meant to be one; the wall *is* the swept path of the tool. That's
    /// realistic for a same-width channel, but most people don't draw a slot as its
    /// own centerline in CAD -- they draw the slot's actual physical boundary (the
    /// walls a same-width tool would leave behind), the same way they'd draw any
    /// other feature. This step bridges that gap for the rectangular case: given the
    /// boundary a straight, same-width slot would actually have -- a plain rectangle,
    /// one dimension matching `tool.diameter` exactly, square-cornered because a
    /// round tool can't help but leave rounded ends when it traces the middle -- this
    /// derives the single centerline segment that reproduces exactly that boundary
    /// when traced by `tool.diameter`, ready to hand straight to
    /// `generateToolpaths(from:tool:settings:operation:)` the same as any other
    /// `.slotting` centerline.
    ///
    /// Deliberately narrow, matching the rest of `.slotting`'s own scope: a plain
    /// 4-straight-side rectangle only, one pair of opposite sides within
    /// `tolerance` of `tool.diameter` (the slot's width), the other pair becoming the
    /// long axis the centerline runs along. Returns `nil` -- rather than guessing --
    /// for anything that isn't recognizably that shape: not exactly 4 segments, any
    /// segment that isn't a straight line (already excludes a stadium/rounded-rectangle
    /// boundary, which has no single unambiguous width to validate against without a
    /// two-radius fit), corners that aren't right angles, opposite sides that aren't
    /// equal length, or neither side pairing landing within `tolerance` of the tool's
    /// own diameter -- a slot whose walls don't actually match the tool cutting it
    /// isn't a `.slotting` case at all yet (see this function's own doc note on
    /// `SlottingPattern`, still unwired, for the wider-than-tool case).
    ///
    /// > Flag: a circular channel/groove needs no equivalent derivation -- a single
    /// > circle already fully specifies its own centerline (`buildSlottingToolpath`
    /// > traces whatever contour it's handed, open or closed, straight lines or arcs),
    /// > so a user can draw the desired circular path directly and use it as-is. The
    /// > *boundary* equivalent of this rectangle case -- two concentric circles W
    /// > apart, forming a true annular slot boundary rather than its already-known
    /// > centerline -- can't be accepted yet: two disjoint circles have no
    /// > "these two loops are one feature" relationship in `SC.Contour`'s current flat
    /// > entity-list model, the same structural gap already blocking pocket islands
    /// > and `.morph` (see `ROADMAP.md`, end of Track 1 and Step 1B.3). Revisit once
    /// > that model change lands; until then, circular slots are drawn as their own
    /// > centerline, not derived from a boundary.
    public func rectangleSlotCenterline(fromBoundary contour: SC.Contour,
                                 tool: SC.ToolParams,
                                 tolerance: Double = 1e-3) -> SC.Contour? {

        guard contour.isClosed else {
            return nil
        }

        let segments = linearize(contour: contour)
        guard segments.count == 4 else {
            return nil
        }

        // Every side must be a straight line -- a stadium/rounded-rectangle boundary
        // (2 lines + 2 arcs) isn't handled by this path (see doc comment above).
        var vertices: [CGPoint] = []
        for segment in segments {
            guard case .line = segment else {
                return nil
            }
            vertices.append(segment.startPoint)
        }

        let a = vertices[0], b = vertices[1], c = vertices[2], d = vertices[3]

        let lengthAB = hypot(b.x - a.x, b.y - a.y)
        let lengthBC = hypot(c.x - b.x, c.y - b.y)
        let lengthCD = hypot(d.x - c.x, d.y - c.y)
        let lengthDA = hypot(a.x - d.x, a.y - d.y)

        // Opposite sides equal length -- a necessary (not sufficient on its own,
        // see the perpendicularity check below) condition for a rectangle.
        guard abs(lengthAB - lengthCD) < tolerance, abs(lengthBC - lengthDA) < tolerance,
              lengthAB > tolerance, lengthBC > tolerance else {
            return nil
        }

        // Adjacent sides must be perpendicular -- rules out a non-rectangular
        // parallelogram that happens to have equal opposite side lengths.
        func isPerpendicular(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint) -> Bool {
            let v1 = CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
            let v2 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
            let len1 = hypot(v1.x, v1.y)
            let len2 = hypot(v2.x, v2.y)
            guard len1 > tolerance, len2 > tolerance else { return false }
            let cosAngle = (v1.x * v2.x + v1.y * v2.y) / (len1 * len2)
            return abs(cosAngle) < tolerance * 10 // near-zero dot product, scaled for the same tolerance
        }
        guard isPerpendicular(a, b, c), isPerpendicular(b, c, d) else {
            return nil
        }

        // Which side pairing is the slot's width (must match tool.diameter) and which
        // is the long axis the centerline runs along.
        let longAxisStart: CGPoint
        let longAxisEnd: CGPoint
        let length: Double
        let width: Double
        if abs(lengthBC - tool.diameter) < tolerance {
            // BC/DA are the width ends -- AB/CD run along the long axis.
            width = lengthBC
            length = lengthAB
            longAxisStart = a
            longAxisEnd = b
        } else if abs(lengthAB - tool.diameter) < tolerance {
            // AB/CD are the width ends -- BC/DA run along the long axis.
            width = lengthAB
            length = lengthBC
            longAxisStart = b
            longAxisEnd = c
        } else {
            // Neither side pairing matches the tool's own diameter -- this rectangle
            // isn't a same-width slot boundary for this tool at all.
            return nil
        }

        // Inset the centerline by tool.diameter / 2 from each end -- the tool radius
        // the swept circle needs to reach exactly the rectangle's own short ends
        // (rounding what would otherwise be its square corners), rather than
        // overshooting past them. A rectangle no longer than its own width has no
        // straight run left once both ends are inset.
        guard length > width else {
            return nil
        }

        let center = CGPoint(x: (a.x + b.x + c.x + d.x) / 4.0, y: (a.y + b.y + c.y + d.y) / 4.0)
        let dir = CGPoint(x: (longAxisEnd.x - longAxisStart.x) / length, y: (longAxisEnd.y - longAxisStart.y) / length)
        let halfCenterlineLength = (length - width) / 2.0

        let start = CGPoint(x: center.x - dir.x * halfCenterlineLength, y: center.y - dir.y * halfCenterlineLength)
        let end = CGPoint(x: center.x + dir.x * halfCenterlineLength, y: center.y + dir.y * halfCenterlineLength)

        return SC.Contour(entities: [
            SC.Contour.Chained(entity: .line(a: DXF.Point(start.x, start.y), b: DXF.Point(end.x, end.y), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
    }
}
