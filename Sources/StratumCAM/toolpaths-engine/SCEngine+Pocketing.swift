//
//  SCEngine+Pocketing.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// Builds the pocket toolpath for either `PocketType`. Both patterns share the same
    /// closed-contour validation and Z-stepdown/waypoint wrapper -- they only differ in
    /// how they produce `toolpathSegments`. `entry` (plunge/ramp/helix) is wired into the
    /// first plunge point for both pattern types as of Step 1.2, reusing the same
    /// `rampWaypoints`/`helixEntryWaypoints` machinery `.contour` uses -- see
    /// `buildPocketWaypoints` below. As of Step 1.3, `toolpathSegments` (the ring stack or
    /// raster rows) is computed exactly once outside the Z loop and reused for every pass
    /// -- re-deriving rings/scanlines per depth would be wasted work and risks two passes
    /// silently diverging in geometry.
    func buildPocketToolpath(for contour: SC.Contour,
                             tool: SC.ToolParams,
                             settings: SC.MachineSettings,
                             direction: SC.CutDirection,
                             pattern: SC.PocketClearingPattern,
                             entry: SC.EntryStrategy,
                             operation: SC.MachiningOperation) -> SC.OutputToolpath? {

        guard contour.isClosed else {
            return nil
        }

        let baseSegments = contour.linearizedSegments
        guard !baseSegments.isEmpty else {
            return nil
        }

        let toolpathSegments: [SC.Segment]

        // The real, closed pocket-wall boundary -- distinct from `toolpathSegments`
        // below. `.helix` entry needs a genuinely closed loop to compute which side
        // of the tool's path is "inside" (see `isCCWWinding`'s shoelace calculation,
        // which is only meaningful for a closed boundary); `toolpathSegments` itself
        // is a closed loop for `.offsetPattern` (each ring is the wall, re-offset) but
        // is an open, direction-alternating zig-zag for `.raster` (the chained scan
        // rows), so it must not be reused for that purpose -- see `buildPocketWaypoints`.
        let boundarySegments: [SC.Segment]

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
                    return nil
                }

                // 3. Chain the rings into one continuous cut path with connecting
                // transitions between them (Step 2.2b, done).
                toolpathSegments = chainedRingSegments(rings)

            case .raster:
                // Raster clips its scanlines against the same tool-radius wall offset
                // the ring stack starts from (Step 2.1's boundary) -- reuse it rather
                // than offsetting the contour twice. Direction here doesn't need
                // `orientedForDirection`: it only decides which way the first scanline
                // row travels, not the wall's own winding.
                let wallOffset = offsetContour(baseSegments, side: .inside, toolRadius: tool.diameter / 2.0, isClosed: true)
                guard !wallOffset.isEmpty else {
                    return nil
                }
                boundarySegments = wallOffset

                let stepover = settings.cutting.stepoverPercentage * tool.diameter
                let rows = rasterScanlines(within: wallOffset, stepover: stepover, direction: direction)
                guard !rows.isEmpty else {
                    return nil
                }

                // Same chaining helper the ring stack uses -- a raster row list is just
                // another ordered stack of segment groups needing connecting transitions
                // between them.
                toolpathSegments = chainedRingSegments(rows)

            case .spiral(let spiralDirection):
                // Same climb/conventional wall orientation as `.offsetPattern` -- a
                // spiral pocket is still, at heart, the same concentric-ring shape.
                let oriented = orientedForDirection(baseSegments, side: .inside, direction: direction)
                boundarySegments = oriented

                // The discrete ring stack is reused either way: as the interpolation
                // control points for a true spiral (below), or, on the fallback path,
                // exactly as `.offsetPattern` already chains them. Always generated
                // outside-in regardless of `spiralDirection` -- Step 1B.1b's direction
                // only decides which end of this same stack `spiralSegments` starts and
                // finishes at, not how the stack itself is built.
                let rings = pocketRings(from: oriented, tool: tool, stepoverPercentage: settings.cutting.stepoverPercentage)
                guard !rings.isEmpty else {
                    return nil
                }

                if isSpiralEligible(oriented) {
                    toolpathSegments = spiralSegments(from: rings, direction: spiralDirection)
                } else {
                    // Per the `.spiral` case's own doc comment, this only has a
                    // well-defined single center on a circular boundary -- anything
                    // else (a rectangle, an arbitrary polygon, even an ellipse or
                    // near-symmetrical shape this doesn't specifically detect) falls
                    // back to the exact ring-and-chain path `.offsetPattern` uses,
                    // rather than spiraling around a center that doesn't actually fit
                    // the boundary. See `isSpiralEligible`. `spiralDirection` has no
                    // say here either way -- per Step 1B.1b, direction only matters
                    // once a boundary is already spiral-eligible.
                    toolpathSegments = chainedRingSegments(rings)
                }

            case .trochoidal(let trochoidalSettings):
                // Full interior clearing, not just a bounce along the outer wall: reuse
                // the exact same tool-radius-inset wall boundary and raster row
                // generation `.raster` itself uses -- already correctly covers the
                // whole interior, respecting concave boundaries and islands, splitting
                // a row wherever the boundary itself does -- then expand each row into
                // a chain of overlapping full circular loops instead of tracing it as
                // a straight line. See `loopedTrochoidalSegments`'s own doc comment for
                // why a full loop (not `.slotting`'s own wall-to-wall bounce) is the
                // right shape here: the *next row over*, not a second wall, is what
                // provides the rest of the coverage.
                let wallOffset = offsetContour(baseSegments, side: .inside, toolRadius: tool.diameter / 2.0, isClosed: true)
                guard !wallOffset.isEmpty else {
                    return nil
                }
                boundarySegments = wallOffset

                let stepover = settings.cutting.stepoverPercentage * tool.diameter
                let rows = rasterScanlines(within: wallOffset, stepover: stepover, direction: direction)
                guard !rows.isEmpty else {
                    return nil
                }
                let rowChain = chainedRingSegments(rows)

                toolpathSegments = loopedTrochoidalSegments(from: rowChain,
                                                             tool: tool,
                                                             radialEngagement: trochoidalSettings.radialEngagement)

            case .adaptive:
                fatalError("Not implemented yet")
            case .morph:
                fatalError("Not implemented yet")
        }

        guard !toolpathSegments.isEmpty else {
            return nil
        }

        let zDepths = EngineTools.calculateZPasses(targetDepth: settings.targetDepth, stepdown: settings.cutting.stepdown)

        var passes: [SC.ToolpathPass] = []
        var previousZ = 0.0 // top of stock -- pass 0 ramps/helixes down from here, same convention `.contour` uses.
        for (i, z) in zDepths.enumerated() {
            let waypoints = buildPocketWaypoints(for: toolpathSegments,
                                                 boundary: boundarySegments,
                                                 atZ: z,
                                                 previousZ: previousZ,
                                                 settings: settings,
                                                 entry: entry)
            passes.append(SC.ToolpathPass(passIndex: i, depthZ: z, waypoints: waypoints))
            previousZ = z
        }

        return SC.OutputToolpath(operation: operation,
                                 tool: tool,
                                 settings: settings,
                                 passes: passes)
    }

    // MARK: - Pocket entry

    /// Wraps `segments` (an already-chained ring stack or raster row list) with an entry
    /// move honoring `entry`, then traces the geometry and retracts -- same three-phase
    /// shape as `.contour`'s `buildProfileWaypoints`, just without the lead-in/lead-out/tab
    /// machinery pocketing doesn't have.
    ///
    /// `.plunge` is exactly the existing straight-down wrapper (`buildWaypoints`) --
    /// nothing to change there; like `.contour`'s plunge entry, it always retracts to
    /// safeZ and re-plunges fresh on every pass rather than reading `previousZ`. `.ramp`
    /// and `.helix` are a thin reuse of `SCEngine+Contour.swift`'s
    /// `rampWaypoints`/`helixEntryWaypoints`: as of Step 1.3, each pass ramps/helixes only
    /// from `previousZ` (the depth the previous pass already reached) down to `z`, not
    /// from top-of-stock every time -- the same "only cover this pass's fresh stepdown"
    /// convention `.contour`'s ramp/helix entry already uses. The first pass's
    /// `previousZ` is `0` (top of stock), matching `.contour`'s own first-pass behavior.
    ///
    /// `side` is hardcoded to `.inside` for the helix's signed-offset calculation --
    /// pocketing has no separate inside/outside concept the way `.contour` does (the
    /// wall offset is already baked into `toolpathSegments`), and `.inside` matches the
    /// convention `orientedForDirection`/`pocketRings` already use elsewhere in this file.
    ///
    /// `boundary` is the real, closed pocket-wall loop and is deliberately separate from
    /// `segments` (the cutting geometry): the helix's signed-offset calculation needs a
    /// genuinely closed loop to determine which side of the tool's path is "inside" the
    /// wall (see `isCCWWinding`). For `.offsetPattern`, `segments` (the chained ring
    /// stack) happens to also be closed, but for `.raster`, `segments` is an open,
    /// direction-alternating zig-zag of scan rows -- treating that as a closed loop
    /// produces an arbitrary offset sign and can send the helix spiraling outside the
    /// pocket's own bounding box. `boundary` is always the one true closed wall,
    /// regardless of pattern, so the helix stays consistently on the safe side of it.
    private func buildPocketWaypoints(for segments: [SC.Segment],
                                      boundary: [SC.Segment],
                                      atZ z: Double,
                                      previousZ: Double,
                                      settings: SC.MachineSettings,
                                      entry: SC.EntryStrategy) -> [SC.Waypoint] {

        guard let firstSegment = segments.first else {
            return []
        }

        guard entry != .plunge else {
            return buildWaypoints(for: segments, atZ: z, settings: settings)
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
                                                              side: .inside,
                                                              segments: boundary,
                                                              firstSegment: firstSegment,
                                                              radius: radius,
                                                              angleDegrees: angleDegrees,
                                                              fromZ: previousZ,
                                                              toZ: z,
                                                              settings: settings)
                )
            case .fromOpenEnd(stepoverPercentage: _):
                break;
        }

        // Trace the chained pocket geometry -- mirrors `buildWaypoints`' own trace step.
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

    // MARK: - Step 2.2a: ring geometry

    /// Generates the concentric ring stack for `.offsetPattern` pocketing, geometry
    /// only -- no waypoints yet (that's `chainedRingSegments` + `buildWaypoints`).
    ///
    /// The first ring is the same tool-radius wall offset as Step 2.1. Every ring
    /// after that steps a further `stepoverPercentage * tool.diameter` inward --
    /// the standard center-to-center spacing between adjacent passes for a given
    /// stepover percentage -- by re-offsetting the previous ring rather than the
    /// original boundary.
    ///
    /// Rings are returned **outside-in** (boundary ring first, smallest ring last).
    /// That ordering is a deliberate choice, not incidental: `chainedRingSegments`
    /// cuts them in this same order, so the tool always steps from a ring it just
    /// finished into the fresh stepover band immediately inside it, rather than
    /// jumping between non-adjacent rings. The innermost ring -- the one nearest
    /// anything an eventual island might occupy -- is always cut last.
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

            rings.append(next)
            current = next
        }

        return rings
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
    /// center and radius, i.e. a full circle. That's the shape a DXF `.circle` entity
    /// linearizes into (two 180° arcs of matching center/radius -- see `SCEngine.swift`'s
    /// `.circle` case), so a plain circular pocket boundary is always detected here.
    ///
    /// The `.spiral` case's own doc comment also allows "elliptical, or near-symmetrical"
    /// boundaries, but this doesn't attempt to detect those: an ellipse has no single
    /// radius to check against, and "near-symmetrical" has no crisp definition at all.
    /// Rather than guess and risk spiraling around a center that doesn't actually fit the
    /// boundary, anything that isn't a plain circle -- including ellipses, rounded
    /// rectangles, and arbitrary polygons -- takes the `.offsetPattern` ring-and-chain
    /// fallback in `buildPocketToolpath` above instead.
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
        guard stepover > 1e-6, !boundary.isEmpty else {
            return []
        }

        let box = boundary.boundingBox
        let span = box.maxY - box.minY
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
            // isn't actually inside the pocket).
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

    /// Turns the same oriented boundary chain `.offsetPattern`/`.spiral` build via
    /// `orientedForDirection` (or, for `.slotting`, a slot's own centerline) into a
    /// chain of semicircular "bites" that bounce the cutter between the two walls
    /// constraining it, rather than tracing/offsetting the boundary directly or
    /// looping in full circles centered on it.
    ///
    /// Picture milling a slot: the tool sits against one wall, swings across in a
    /// semicircle engaging only `radialEngagement` (a fraction of `tool.diameter`)
    /// of fresh material, then a straight line finishes the reach to the opposite
    /// wall through material the previous bite (coming from the other direction)
    /// already cleared. The tool then advances along the boundary and repeats,
    /// starting its next bite from the wall it's now sitting against -- so
    /// consecutive bites alternate sides, tracing a zig-zag of "D"-shaped lobes
    /// down the boundary instead of a straight chain of full circles along its
    /// centerline.
    ///
    /// The two walls are `2 * loopRadius` apart, centered on the boundary itself
    /// (wall offsets of `+loopRadius`/`-loopRadius` from it) -- for `.pocket`'s
    /// wall-following case that's the real wall plus a virtual "far wall"
    /// `loopRadius` into the open pocket; for a `.slotting` centerline with
    /// `loopRadius == tool.diameter / 2`, that's the slot's own two real walls.
    /// If a single bite's engagement (`radialEngagement * tool.diameter`) already
    /// reaches or exceeds the full `2 * loopRadius` gap, the semicircle alone
    /// spans wall to wall and the straight "reach the opposite wall" bridge is
    /// skipped (there's no gap left to cross).
    ///
    /// Each semicircle is tessellated at the same 5-degree-per-step resolution
    /// `spiralSegments`'s full circles use (this is real cutting motion, not a
    /// short entry hop, so facets on the wall matter). Bites are connected by
    /// short straight advance moves from one bite's own finishing point to the
    /// next bite's starting point, mirroring `chainedRingSegments`'s
    /// one-move-per-transition convention.
    func trochoidalSegments(from orientedBoundary: [SC.Segment],
                            tool: SC.ToolParams,
                            radialEngagement: Double,
                            loopRadius: Double) -> [SC.Segment] {

        guard !orientedBoundary.isEmpty else {
            return []
        }
        guard loopRadius > 1e-9 else {
            return []
        }

        // How much fresh material (as a fraction of tool.diameter) each single
        // bite engages, clamped so a single semicircle never tries to overshoot
        // past the far wall -- see this function's own doc comment.
        let penetration = min(radialEngagement * tool.diameter/2, loopRadius * tool.diameter/2)
        guard penetration > 1e-6 else {
            return []
        }

        let totalLength = orientedBoundary.pathLength
        guard totalLength > 1e-9 else {
            return []
        }

        // Bites start every `penetration` along the boundary, starting at distance
        // 0 and finishing with a final bite pinned exactly at the boundary's own
        // end -- same fencepost convention `rasterScanlines` uses for its last row
        // and `calculateZPasses` uses for its last Z depth, rather than landing
        // short of, or past, the boundary's true end.
        let rawSteps = totalLength / penetration
        let epsilon = 1e-9
        let stepCount: Int
        if abs(rawSteps.rounded() - rawSteps) < epsilon {
            stepCount = max(1, Int(rawSteps.rounded()))
        } else {
            stepCount = max(1, Int(rawSteps.rounded(.up)))
        }
        let cycleCount = stepCount + 1

        let cycleDistances: [Double] = (0..<cycleCount).map { i in
            (i == cycleCount - 1) ? totalLength : penetration * Double(i)
        }

        let stepsPerSemicircle = 36 // half of `spiralSegments`'s 72-step full circle -- same 5 degrees/step.
        let hasBridge = penetration < (2 * loopRadius - 1e-9)

        var segments: [SC.Segment] = []
        var previousFinish: CGPoint?

        for (i, distance) in cycleDistances.enumerated() {
            let origin = point(alongPath: orientedBoundary, distance: distance, totalLength: totalLength)
            let travelDirection = tangent(alongPath: orientedBoundary, distance: distance, totalLength: totalLength)
            let normal = CGPoint(x: -travelDirection.y, y: travelDirection.x)

            // Bites alternate which wall they start from -- the wall this bite
            // finishes against is exactly where the next bite starts.
            let side: Double = (i % 2 == 0) ? -1.0 : 1.0

            func local(_ u: Double, _ v: Double) -> CGPoint {
                CGPoint(x: origin.x + u * travelDirection.x + v * normal.x,
                        y: origin.y + u * travelDirection.y + v * normal.y)
            }

            let start = local(0, side * loopRadius)

            // Advance move from the previous bite's finishing point (already
            // sitting on this bite's own starting wall) to this bite's start.
            if let previousFinish, hypot(start.x - previousFinish.x, start.y - previousFinish.y) > 1e-6 {
                segments.append(.line(start: previousFinish, end: start))
            }

            // The semicircle itself: a "D"-shaped lobe whose flat side runs along
            // this wall from `side * loopRadius` to `side * (loopRadius -
            // penetration)`, bulging forward (in the direction of travel) by
            // `penetration / 2` at its midpoint -- see this function's own doc
            // comment for the geometry this reproduces.
            let semicircleRadius = penetration / 2
            let centerV = side * (loopRadius - penetration / 2)
            let startAngle = side * (Double.pi / 2)
            let sweepSign = -side // sweeps through angle 0 (the forward bulge), never through pi (backward).

            var previousPoint = start
            for step in 1...stepsPerSemicircle {
                let t = Double(step) / Double(stepsPerSemicircle)
                let angle = startAngle + sweepSign * Double.pi * t
                let nextPoint = local(semicircleRadius * cos(angle), centerV + semicircleRadius * sin(angle))
                segments.append(.line(start: previousPoint, end: nextPoint))
                previousPoint = nextPoint
            }

            // Straight line finishing the reach to the opposite wall, through
            // material the previous (opposite-direction) bite already cleared --
            // skipped when this bite's own penetration already reached that wall.
            if hasBridge {
                let oppositeWall = local(0, -side * loopRadius)
                segments.append(.line(start: previousPoint, end: oppositeWall))
                previousFinish = oppositeWall
            } else {
                previousFinish = previousPoint
            }
        }

        return segments
    }

    /// Expands `path` (an already fully interior-covering, direction-oriented
    /// chain -- e.g. the same chained raster row stack `.raster` itself traces)
    /// into a series of overlapping full circular loops advancing along it,
    /// instead of tracing the path directly as straight/arc segments.
    ///
    /// Each loop is a true full circle of radius `tool.diameter / 2`, centered
    /// exactly on the path at that point. Unlike `.slotting`'s own wall-to-wall
    /// bounce (`SCEngine+Slotting.swift`'s `openEndedTrochoidalSegments`), there's
    /// no second wall to bounce against here: `path` already comes from
    /// `rasterScanlines` against a boundary inset by the tool's own radius, so
    /// every point on it is guaranteed at least `tool.diameter / 2` from every
    /// true wall -- a full circle centered there can never cross it. The *next
    /// row over* (not a second wall) is what provides the rest of the lateral
    /// coverage, so each loop only needs to engage material gradually as it
    /// advances, not span between two hard constraints.
    ///
    /// `radialEngagement` (clamped to `0...1`) sets the forward pitch between
    /// consecutive loop centers, as a fraction of `tool.diameter / 2` (the
    /// tool's own radius) -- same convention `.slotting`'s own
    /// `stepoverPercentage` uses (see that file's doc comment for why a
    /// percentage is measured against a single radius here, not the full
    /// diameter).
    func loopedTrochoidalSegments(from path: [SC.Segment], tool: SC.ToolParams, radialEngagement: Double) -> [SC.Segment] {
        guard !path.isEmpty else {
            return []
        }
        let loopRadius = tool.diameter / 2.0
        guard loopRadius > 1e-9 else {
            return []
        }

        let clampedEngagement = min(max(radialEngagement, 0), 1)
        let pitch = max(clampedEngagement, 1e-3) * loopRadius
        guard pitch > 1e-6 else {
            return []
        }

        let totalLength = path.pathLength
        guard totalLength > 1e-9 else {
            return []
        }

        // Loops start every `pitch` along the path, starting at distance 0 and
        // finishing with a final loop pinned exactly at the path's own end --
        // same fencepost convention `trochoidalSegments`/`openEndedTrochoidalSegments`
        // already use.
        let rawSteps = totalLength / pitch
        let epsilon = 1e-9
        let stepCount: Int
        if abs(rawSteps.rounded() - rawSteps) < epsilon {
            stepCount = max(1, Int(rawSteps.rounded()))
        } else {
            stepCount = max(1, Int(rawSteps.rounded(.up)))
        }
        let cycleCount = stepCount + 1

        let cycleDistances: [Double] = (0..<cycleCount).map { i in
            (i == cycleCount - 1) ? totalLength : pitch * Double(i)
        }

        let stepsPerLoop = 72 // same 5-degrees/step resolution `spiralSegments` uses.

        var segments: [SC.Segment] = []
        var previousFinish: CGPoint?

        for distance in cycleDistances {
            let center = point(alongPath: path, distance: distance, totalLength: totalLength)
            let start = CGPoint(x: center.x + loopRadius, y: center.y)

            if let previousFinish, hypot(start.x - previousFinish.x, start.y - previousFinish.y) > 1e-6 {
                segments.append(.line(start: previousFinish, end: start))
            }

            var previousPoint = start
            for step in 1...stepsPerLoop {
                let t = Double(step) / Double(stepsPerLoop)
                let angle = t * 2 * Double.pi
                let nextPoint = CGPoint(x: center.x + loopRadius * cos(angle), y: center.y + loopRadius * sin(angle))
                segments.append(.line(start: previousPoint, end: nextPoint))
                previousPoint = nextPoint
            }

            previousFinish = previousPoint
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
                let sweep = isCCW ? (endAngle - startAngle) : (startAngle - endAngle)
                let angle = startAngle + (isCCW ? 1.0 : -1.0) * abs(sweep) * t
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
                let sweep = isCCW ? (endAngle - startAngle) : (startAngle - endAngle)
                let angle = startAngle + (isCCW ? 1.0 : -1.0) * abs(sweep) * t
                let radialX = cos(angle), radialY = sin(angle)
                return isCCW ? CGPoint(x: -radialY, y: radialX) : CGPoint(x: radialY, y: -radialX)
        }
    }
}
