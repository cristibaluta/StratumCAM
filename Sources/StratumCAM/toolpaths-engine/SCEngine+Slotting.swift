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
                               pattern: SC.SlotClearingPattern,
                               depthPerPass: Double,
                               entry: SC.EntryStrategy,
                               operation: SC.MachiningOperation) -> SC.OutputToolpath? {

        let segments = contour.linearizedSegments
        guard let firstSegment = segments.first else {
            return nil
        }

        let zDepths = EngineTools.calculateZPasses(targetDepth: settings.targetDepth, stepdown: depthPerPass)

        var passes: [SC.ToolpathPass] = []
        var previousZ = 0.0 // top of stock -- pass 0 ramps/helixes down from here, same convention `.contour`/`.pocket` use.
        for (i, z) in zDepths.enumerated() {
            let waypoints = buildSlottingWaypoints(for: segments,
                                                   firstSegment: firstSegment,
                                                   tool: tool,
                                                   atZ: z,
                                                   previousZ: previousZ,
                                                   settings: settings,
                                                   pattern: pattern,
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
                                        tool: SC.ToolParams,
                                        atZ z: Double,
                                        previousZ: Double,
                                        settings: SC.MachineSettings,
                                        pattern: SC.SlotClearingPattern,
                                        entry: SC.EntryStrategy) -> [SC.Waypoint] {

        guard entry != .plunge else {
            return buildWaypoints(for: segments, atZ: z, settings: settings)
        }

        if case .fromOpenEnd(let stepoverPercentage) = entry {
            return buildOpenEndedSlottingWaypoints(for: segments,
                                                    tool: tool,
                                                    atZ: z,
                                                    settings: settings,
                                                    stepoverPercentage: stepoverPercentage)
        }

        let startPoint = firstSegment.startPoint
        let startTangent = direction(of: firstSegment, atEnd: false)

        var waypoints: [SC.Waypoint] = [
            SC.Waypoint(position: SIMD3(startPoint.x, startPoint.y, settings.safeZ),
                        motion: .rapid,
                        feedRate: settings.cutting.feedRate)
        ]

        switch entry {
            case .plunge:
                break // Handled above via `buildWaypoints`.

            case .fromOpenEnd:
                break // Handled above via `buildOpenEndedSlottingWaypoints`.

            case .ramp(let angleDegrees):
                waypoints.append(
                    contentsOf: RampTools.rampWaypoints(firstSegment: firstSegment,
                                                        angleDegrees: angleDegrees,
                                                        fromZ: previousZ,
                                                        toZ: z,
                                                        settings: settings)
                )

            case .helix(let radius, let angleDegrees):
                waypoints.append(
                    contentsOf: RampTools.helixEntryWaypoints(contourStart: startPoint,
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

    /// `.fromOpenEnd`'s own trace step -- expands `segments` (the derived
    /// centerline, already extended past the open mouth by
    /// `openEndedSlotCenterline`) into a chain of overlapping trochoidal bites via
    /// `trochoidalSegments`, the same wall-to-wall bounce machinery `.pocket`'s own
    /// `.trochoidal` pattern already uses for its own wall boundary, then hands
    /// that expanded chain to the ordinary `buildWaypoints` wrapper -- exactly the
    /// way `.pocket`'s `buildPocketWaypoints` already treats `.trochoidal` +
    /// `.plunge` together (`case .plunge: return buildWaypoints(for: segments,
    /// ...)`, where `segments` there is likewise the post-trochoidal-expansion
    /// chain, not the raw boundary). That means the rapid-then-plunge lands
    /// exactly on the first bite's own start point (out in free air, per the
    /// centerline's own extension), not the raw centerline's start -- there's no
    /// separate Z-entry move to write here at all, since engagement builds up
    /// gradually bite by bite as soon as the trace itself begins.
    ///
    /// This centerline's own two walls sit exactly `tool.diameter` apart (see
    /// `openEndedSlotCenterline`'s own doc comment), so `loopRadius` here is
    /// `tool.diameter / 2` -- both of `trochoidalSegments`' walls are the slot's
    /// real walls, not one real and one virtual the way `.pocket`'s own wall
    /// clearing uses it.
    private func buildOpenEndedSlottingWaypoints(for segments: [SC.Segment],
                                                 tool: SC.ToolParams,
                                                 atZ z: Double,
                                                 settings: SC.MachineSettings,
                                                 stepoverPercentage: Double) -> [SC.Waypoint] {

        let loopSegments = trochoidalSegments(from: segments,
                                              tool: tool,
                                              radialEngagement: stepoverPercentage,
                                              loopRadius: tool.diameter / 2.0)
        return buildWaypoints(for: loopSegments, atZ: z, settings: settings)
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

        let segments = contour.linearizedSegments
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
        guard isPerpendicularCorner(a, b, c, tolerance: tolerance),
              isPerpendicularCorner(b, c, d, tolerance: tolerance) else {
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

    // MARK: - Slot boundary recognition (open-ended "U" -> centerline)

    /// The open-ended counterpart to `rectangleSlotCenterline` above: a slot whose
    /// boundary runs off the edge of the stock rather than closing back on itself
    /// on all four sides. Physically that boundary is a "U" -- two parallel walls
    /// `tool.diameter` apart, joined by one closed short end, with the opposite
    /// short end left off the drawing entirely, since that's where the stock ends
    /// and free air begins; there's no wall to draw there. Exactly 3 straight
    /// segments, `contour.isClosed == false`, ordered the way any of these fixtures
    /// naturally is: side one from the open mouth to the closed corner, across the
    /// closed end, then side two from the other closed corner back out to the
    /// mouth (see `Slotting_Tests.swift`/`DemoSlotting.swift`'s own fixture for the
    /// exact shape expected).
    ///
    /// Returns a centerline that starts `approachDistance` *before* the open mouth
    /// -- out in free air, clear of the stock -- and ends inset by the tool radius
    /// from the closed end, the same rounding-the-square-corner reasoning
    /// `rectangleSlotCenterline` already uses at both of its ends. The extension
    /// past the mouth is what lets `.fromOpenEnd` rapid straight down to depth and
    /// start its first trochoidal loop already clear of material, rather than
    /// starting exactly at the stock edge and engaging full width immediately.
    ///
    /// `approachDistance` defaults to `tool.diameter` -- enough clearance that the
    /// first trochoidal loop (radius `tool.diameter / 2`) doesn't touch the stock
    /// edge at all before the tool is already at full depth.
    ///
    /// Deliberately as narrow in scope as `rectangleSlotCenterline`: only a plain
    /// 3-straight-segment "U", one pair of opposite (side) walls within
    /// `tolerance` of `tool.diameter`, both corners against the closed end square.
    /// Returns `nil` for anything that isn't recognizably that shape -- a closed
    /// contour (that's `rectangleSlotCenterline`'s own case), not exactly 3
    /// segments, a curved side, corners that aren't right angles, side walls of
    /// unequal length, a closed end that isn't `tool.diameter` wide, or a slot no
    /// longer than its own width once the closed end is inset -- rather than
    /// guessing.
    ///
    /// > Flag: same wider-than-tool gap `rectangleSlotCenterline` already flags --
    /// > this only ever derives a centerline for a slot exactly `tool.diameter`
    /// > wide. A boundary wider than the tool needs the pattern-based clearing
    /// > `SlottingPattern.raster`/`.trochoidal` describe (model exists, still
    /// > unwired into `.slotting`), not this recognition step.
    public func openEndedSlotCenterline(fromBoundary contour: SC.Contour,
                                        tool: SC.ToolParams,
                                        approachDistance: Double? = nil,
                                        tolerance: Double = 1e-3) -> SC.Contour? {

        guard !contour.isClosed else {
            return nil
        }

        let segments = contour.linearizedSegments
        guard segments.count == 3 else {
            return nil
        }

        // TODO: should take curved lines
        // Every side must be a straight line -- no curved walls handled here.
        for segment in segments {
            guard case .line = segment else {
                return nil
            }
        }

        // p0 -> p1: first side wall, mouth to closed corner.
        // p1 -> p2: the closed end itself.
        // p2 -> p3: second side wall, closed corner back out to the mouth.
        let p0 = segments[0].startPoint
        let p1 = segments[1].startPoint
        let p2 = segments[2].startPoint
        let p3 = segments[2].endPoint

        let side1Length = hypot(p1.x - p0.x, p1.y - p0.y)
        let side2Length = hypot(p3.x - p2.x, p3.y - p2.y)
        let closedEndLength = hypot(p2.x - p1.x, p2.y - p1.y)

        // The two side walls must be equal length -- a necessary (not sufficient,
        // see the perpendicularity check below) condition for a proper "U".
        guard abs(side1Length - side2Length) < tolerance, side1Length > tolerance else {
            return nil
        }

        // The closed end must match the tool's own diameter -- that's the slot's
        // width, same requirement `rectangleSlotCenterline` places on its own
        // width-pairing side.
        guard abs(closedEndLength - tool.diameter) < tolerance else {
            return nil
        }

        // Both corners against the closed end must be right angles -- together
        // with the equal-length side walls above, this guarantees the two sides
        // are parallel and `closedEndLength` apart along their whole run, ruling
        // out a trapezoidal "U" that happens to have equal-length sides.
        guard isPerpendicularCorner(p0, p1, p2, tolerance: tolerance),
              isPerpendicularCorner(p1, p2, p3, tolerance: tolerance) else {
            return nil
        }

        let mouthMid = CGPoint(x: (p0.x + p3.x) / 2.0, y: (p0.y + p3.y) / 2.0)
        let closedMid = CGPoint(x: (p1.x + p2.x) / 2.0, y: (p1.y + p2.y) / 2.0)
        let length = hypot(closedMid.x - mouthMid.x, closedMid.y - mouthMid.y)

        let toolRadius = tool.diameter / 2.0

        // A "U" no longer than its own width has no straight run left once the
        // closed end is inset by the tool radius -- same fencepost reasoning
        // `rectangleSlotCenterline` applies to both of its own ends.
        guard length > toolRadius else {
            return nil
        }

        let dir = CGPoint(x: (closedMid.x - mouthMid.x) / length, y: (closedMid.y - mouthMid.y) / length)
        let approach = approachDistance ?? tool.diameter

        let start = CGPoint(x: mouthMid.x - dir.x * approach, y: mouthMid.y - dir.y * approach)
        let end = CGPoint(x: closedMid.x - dir.x * toolRadius, y: closedMid.y - dir.y * toolRadius)

        return SC.Contour(entities: [
            SC.Contour.Chained(entity: .line(a: DXF.Point(start.x, start.y), b: DXF.Point(end.x, end.y), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
    }

    // MARK: - Slot boundary recognition (both ends open, "screw head" slot -> centerline)

    /// The both-ends-open counterpart to `openEndedSlotCenterline` above: a slot
    /// whose boundary runs off the edge of the stock on *both* ends rather than
    /// just one -- the classic screw-head slot, cut straight across the part with
    /// free air waiting on either side. Physically that boundary is just two
    /// parallel walls `tool.diameter` apart -- no closed end at all, since there's
    /// no side left where the stock still surrounds the slot. Exactly 2 straight
    /// segments, `contour.isClosed == false`, each one drawn independently (they
    /// don't chain into each other the way a "U"'s 3 segments do, since there's no
    /// shared corner between them) -- see `Slotting_Tests.swift`/
    /// `DemoSlotting.swift`'s own fixture for the exact shape expected.
    ///
    /// Returns a centerline that starts `approachDistance` before one mouth and
    /// ends `approachDistance` past the other -- out in free air on both ends,
    /// clear of the stock -- unlike `rectangleSlotCenterline`/
    /// `openEndedSlotCenterline`, there's no tool-radius inset anywhere, since
    /// there's no closed end left to round off. The extension past both mouths is
    /// what lets `.fromOpenEnd` rapid straight down to depth clear of material on
    /// either side it's handed, and start its first trochoidal loop already clear
    /// of material, rather than starting exactly at a stock edge and engaging full
    /// width immediately.
    ///
    /// `approachDistance` defaults to `tool.diameter`, same convention
    /// `openEndedSlotCenterline` uses -- enough clearance that the first/last
    /// trochoidal loop (radius `tool.diameter / 2`) doesn't touch either stock
    /// edge before the tool is already at full depth.
    ///
    /// Deliberately as narrow in scope as `rectangleSlotCenterline`/
    /// `openEndedSlotCenterline`: only a plain pair of straight, equal-length,
    /// parallel walls exactly `tool.diameter` apart. Returns `nil` -- rather than
    /// guessing -- for anything that isn't recognizably that shape: a closed
    /// contour (that's `rectangleSlotCenterline`'s own case), not exactly 2
    /// segments, a curved wall, walls of unequal length, walls that aren't
    /// parallel, or walls that aren't `tool.diameter` apart.
    ///
    /// > Flag: same wider-than-tool gap `rectangleSlotCenterline`/
    /// > `openEndedSlotCenterline` already flag -- this only ever derives a
    /// > centerline for a slot exactly `tool.diameter` wide. A boundary wider
    /// > than the tool needs the pattern-based clearing `SlottingPattern.raster`/
    /// > `.trochoidal` describe (model exists, still unwired into `.slotting`),
    /// > not this recognition step.
    public func bothEndsOpenSlotCenterline(fromBoundary contour: SC.Contour,
                                           tool: SC.ToolParams,
                                           approachDistance: Double? = nil,
                                           tolerance: Double = 1e-3) -> SC.Contour? {

        guard !contour.isClosed else {
            return nil
        }

        let segments = contour.linearizedSegments
        guard segments.count == 2 else {
            return nil
        }

        // Both walls must be straight lines -- no curved walls handled here.
        for segment in segments {
            guard case .line = segment else {
                return nil
            }
        }

        let a0 = segments[0].startPoint
        let a1 = segments[0].endPoint
        let b0 = segments[1].startPoint
        let b1 = segments[1].endPoint

        let sideLengthA = hypot(a1.x - a0.x, a1.y - a0.y)
        let sideLengthB = hypot(b1.x - b0.x, b1.y - b0.y)

        // Equal-length walls -- a necessary (not sufficient, see the parallel
        // check below) condition for two opposite sides of the same slot.
        guard abs(sideLengthA - sideLengthB) < tolerance, sideLengthA > tolerance else {
            return nil
        }

        // The two segments are drawn independently (no shared corner to chain
        // them the way the "U" case's 3 segments do), so the second wall might
        // run the same rotational way as the first, or the opposite way -- pair
        // each end of wall A with whichever end of wall B is actually nearest it,
        // rather than assuming a fixed start-to-start correspondence.
        let dist00 = hypot(b0.x - a0.x, b0.y - a0.y)
        let dist01 = hypot(b1.x - a0.x, b1.y - a0.y)
        let bNearA0: CGPoint
        let bNearA1: CGPoint
        if dist00 <= dist01 {
            bNearA0 = b0
            bNearA1 = b1
        } else {
            bNearA0 = b1
            bNearA1 = b0
        }

        // Parallel walls -- direction vectors must point the same way once paired
        // by nearest end, ruling out two equal-length lines that happen to be
        // skew to one another.
        let dirA = CGPoint(x: (a1.x - a0.x) / sideLengthA, y: (a1.y - a0.y) / sideLengthA)
        let dirB = CGPoint(x: (bNearA1.x - bNearA0.x) / sideLengthA, y: (bNearA1.y - bNearA0.y) / sideLengthA)
        let cross = dirA.x * dirB.y - dirA.y * dirB.x
        let dot = dirA.x * dirB.x + dirA.y * dirB.y
        guard abs(cross) < tolerance * 10, dot > 0 else {
            return nil
        }

        // The two walls must be tool.diameter apart -- that's the slot's width,
        // same requirement the closed and single-open-end cases place on theirs.
        let separation = hypot(bNearA0.x - a0.x, bNearA0.y - a0.y)
        guard abs(separation - tool.diameter) < tolerance else {
            return nil
        }

        let mouthMid = CGPoint(x: (a0.x + bNearA0.x) / 2.0, y: (a0.y + bNearA0.y) / 2.0)
        let farMid = CGPoint(x: (a1.x + bNearA1.x) / 2.0, y: (a1.y + bNearA1.y) / 2.0)
        let length = hypot(farMid.x - mouthMid.x, farMid.y - mouthMid.y)
        guard length > tolerance else {
            return nil
        }

        let dir = CGPoint(x: (farMid.x - mouthMid.x) / length, y: (farMid.y - mouthMid.y) / length)
        let approach = approachDistance ?? tool.diameter

        // No tool-radius inset at either end -- unlike the closed/single-open-end
        // cases, there's no closed corner left to round off, so both ends simply
        // extend past their own mouth into free air.
        let start = CGPoint(x: mouthMid.x - dir.x * approach, y: mouthMid.y - dir.y * approach)
        let end = CGPoint(x: farMid.x + dir.x * approach, y: farMid.y + dir.y * approach)

        return SC.Contour(entities: [
            SC.Contour.Chained(entity: .line(a: DXF.Point(start.x, start.y), b: DXF.Point(end.x, end.y), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
    }
}

/// Shared by `rectangleSlotCenterline` and `openEndedSlotCenterline`: whether the
/// corner at `p1` (between the leg `p0->p1` and the leg `p1->p2`) is a right
/// angle, i.e. whether the two legs' direction vectors have a near-zero dot
/// product. Free function (not a method) since it needs no `SCEngine` state --
/// pure geometry on three points.
private func isPerpendicularCorner(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, tolerance: Double) -> Bool {
    let v1 = CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
    let v2 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
    let len1 = hypot(v1.x, v1.y)
    let len2 = hypot(v2.x, v2.y)
    guard len1 > tolerance, len2 > tolerance else { return false }
    let cosAngle = (v1.x * v2.x + v1.y * v2.y) / (len1 * len2)
    return abs(cosAngle) < tolerance * 10 // near-zero dot product, scaled for the same tolerance
}
