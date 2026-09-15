//
//  SCEngine+Counterbore.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 15.09.2026.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// Builds a counterbore recess with a normal end mill rather than a dedicated
    /// counterbore/spot-face cutter -- see the `.counterbore` case's own doc comment for
    /// why this is its own operation instead of just drawing the recess as a circle and
    /// running `.pocket` on it.
    ///
    /// Reuses `drillPoint(for:)` for hole-location recognition, same point/closed-circle
    /// contour shapes `.drilling`/`.boring` already accept -- there's no boundary to draw
    /// or offset here, the recess is generated purely from `center`, `diameter`, and the
    /// tool's own radius.
    ///
    /// Clearing pattern: concentric circular rings growing outward from `center`, one
    /// `stepover` band at a time -- the same center-to-center spacing convention
    /// `pocketRings` uses for its own ring stack, just built directly as math circles
    /// instead of by offsetting a drawn boundary, since there is no boundary. Rings are
    /// generated smallest-first (innermost) and chained outward, so the last ring cut is
    /// always the recess's own wall -- the same "wall pass last" reasoning `.spiral`'s
    /// `.insideOut` direction documents for a drawn circular pocket, here just the only
    /// option rather than a choice, since there's no wall to engage first the way a
    /// drawn boundary's own outer ring provides.
    ///
    /// Z stepdown reuses `calculateZPasses`, fed `depth` (this operation's own recess
    /// depth) rather than `settings.targetDepth` -- a job can easily mix holes needing
    /// different screw-head depths, so the depth has to travel with the operation, not
    /// the shared machine settings. As with `.pocket`, the ring geometry itself is
    /// computed once and reused unchanged across every Z pass.
    ///
    /// Throws (Step 6.5, same pattern established in 6.2-6.4) at three sites:
    /// `SC.Error.missingDrillPoint` when the contour isn't a recognizable hole location,
    /// `SC.Error.toolIncompatible` when the tool doesn't fit inside the requested recess
    /// at all, and `SC.Error.geometryCollapsed` if ring generation or chaining somehow
    /// still produces nothing for an otherwise-valid center/diameter/tool combination.
    func buildCounterboreToolpath(for contour: SC.Contour,
                                  tool: SC.ToolParams,
                                  settings: SC.MachineSettings,
                                  diameter: Double,
                                  depth: Double,
                                  direction: SC.CutDirection,
                                  entry: SC.EntryStrategy,
                                  operation: SC.MachiningOperation) throws -> SC.OutputToolpath {

        guard let center = contour.drillPoint else {
            throw SC.Error.missingDrillPoint
        }

        let toolRadius = tool.diameter / 2.0
        // The cutter's own center never needs to travel past this radius for its edge to
        // just reach the recess's finished wall -- same "wall ring = boundary offset
        // inward by tool radius" relationship `pocketRings`' own first ring expresses for
        // a drawn boundary, just derived directly from `diameter` here.
        let wallRadius = abs(diameter) / 2.0 - toolRadius
        guard wallRadius > 1e-6 else {
            // Tool doesn't fit inside the requested recess at all (diameter <= tool
            // diameter) -- same "won't guess, throw rather than silently clamp"
            // convention `pocketRings`' own collapse checks follow elsewhere in this
            // engine, now made explicit via `SC.Error.toolIncompatible`.
            throw SC.Error.toolIncompatible
        }

        // Same climb/conventional winding convention `orientedForDirection` applies to an
        // `.inside` cut (a recess wall, like a pocket wall, is cut from the inside): climb
        // wants the tool travelling CW around the wall, conventional wants CCW.
        let isCCW = direction == .conventional

        let stepover = settings.cutting.stepoverPercentage * tool.diameter
        let rings = counterboreRings(center: center, toolRadius: toolRadius, wallRadius: wallRadius, stepover: stepover, isCCW: isCCW)
        guard !rings.isEmpty, let boundary = rings.last else {
            // Not reachable today -- `wallRadius > 1e-6` is already confirmed above, and
            // `counterboreRings` always appends a wall ring once that holds -- but kept as
            // a `geometryCollapsed` throw rather than an unguarded force-unwrap, matching
            // this codebase's convention elsewhere of not trusting an invariant across a
            // function boundary just because it currently happens to hold.
            throw SC.Error.geometryCollapsed
        }

        let toolpathSegments = chainedRingSegments(rings)
        guard !toolpathSegments.isEmpty else {
            throw SC.Error.geometryCollapsed
        }

        let zDepths = EngineTools.calculateZPasses(targetDepth: depth, stepdown: settings.cutting.stepdown)

        var passes: [SC.ToolpathPass] = []
        var previousZ = 0.0 // top of stock -- pass 0 ramps/helixes down from here, same convention `.pocket`/`.contour` use.
        for (i, z) in zDepths.enumerated() {
            let waypoints = buildCounterboreWaypoints(for: toolpathSegments,
                                                       boundary: boundary,
                                                       atZ: z,
                                                       previousZ: previousZ,
                                                       settings: settings,
                                                       entry: entry,
                                                       center: center)
            passes.append(SC.ToolpathPass(passIndex: i, depthZ: z, waypoints: waypoints))
            previousZ = z
        }

        return SC.OutputToolpath(operation: operation, tool: tool, settings: settings, passes: passes)
    }

    // MARK: - Ring geometry

    /// Generates the concentric ring stack for a counterbore, geometry only -- no
    /// waypoints yet (that's `chainedRingSegments` + `buildCounterboreWaypoints`, same
    /// two-step split `pocketRings`/`chainedRingSegments` use for a drawn pocket).
    ///
    /// Unlike `pocketRings`, which starts from a drawn boundary and offsets inward toward
    /// the center, this has no boundary to start from -- only a center point and the
    /// final wall radius -- so it builds outward instead: the first ring sits one
    /// `stepover` out from `center` (or `toolRadius` out, if that's smaller -- see below),
    /// each following ring steps another `stepover` further out, and the last ring is
    /// always snapped exactly onto `wallRadius` regardless of whether the spacing divides
    /// it evenly (the same fencepost convention `calculateZPasses`/`rasterScanlines`
    /// already use for their own last step). A counterbore small enough that `wallRadius`
    /// doesn't even clear one `stepover` collapses to that single wall ring, which is
    /// also the correct behavior in that case: one full-radius pass is all the recess
    /// needs.
    ///
    /// The first ring is capped at `toolRadius`, not just `stepover`: a ring's own cutter
    /// sweeps an annulus from `radius - toolRadius` to `radius + toolRadius`, so as long as
    /// the first ring's radius is at most `toolRadius`, that annulus reaches all the way
    /// to `center` with no untouched nib left standing at the very middle. `stepover` is
    /// already at most `toolRadius` at the moment (`stepoverPercentage` tops out at 0.95 of
    /// `tool.diameter`, i.e. 1.9x the radius) for a typical stepover, but a stepover close
    /// to that ceiling would otherwise place the first ring's inner sweep edge short of
    /// `center` -- capping at `toolRadius` keeps the guarantee unconditional rather than
    /// depending on the caller's own stepover choice.
    ///
    /// Every ring shares `center` and winds the same way (`isCCW`), so the tool always
    /// steps from a ring it just finished into the fresh stepover band immediately
    /// outside it -- the same "always the adjacent band, never a jump" guarantee
    /// `pocketRings`' own outside-in ordering gives, just walked in the opposite radial
    /// direction here.
    func counterboreRings(center: CGPoint, toolRadius: Double, wallRadius: Double, stepover: Double, isCCW: Bool) -> [[SC.Segment]] {
        // Not converted to `throws` in Step 6.5: by the time anything in this file calls
        // `counterboreRings`, `buildCounterboreToolpath` has already thrown
        // `SC.Error.toolIncompatible` for exactly this condition, so this guard is
        // unreachable through that path -- it exists purely so a direct caller of this
        // internal-but-non-private function (e.g. a test exercising ring geometry alone,
        // as `Counterbore_Tests.swift` already does) gets an empty, unsurprising result
        // instead of a crash, rather than being forced to handle an error that can't
        // happen through the normal toolpath-building call chain.
        guard wallRadius > 1e-6 else {
            return []
        }

        var radii: [Double] = []
        if stepover > 1e-6 {
            var r = min(stepover, toolRadius)
            while r < wallRadius - 1e-6 {
                radii.append(r)
                r += stepover
            }
        }
        radii.append(wallRadius) // Always land exactly on the wall, evenly-divisible spacing or not.

        return radii.map { circleSegments(center: center, radius: $0, isCCW: isCCW) }
    }

    /// A full circle as two 180° arcs, matching `convert(entity:reversed:)`'s existing
    /// DXF-circle handling and `buildBoringToolpath`'s own circular pass -- a single arc
    /// command whose start and end position are identical is ambiguous (zero sweep vs. a
    /// full revolution) on many controllers, so every ring here is split in two as well.
    private func circleSegments(center: CGPoint, radius: Double, isCCW: Bool) -> [SC.Segment] {
        if isCCW {
            return [
                .arc(center: center, radius: radius, startAngle: 0, endAngle: .pi, isCCW: true),
                .arc(center: center, radius: radius, startAngle: .pi, endAngle: 2 * .pi, isCCW: true)
            ]
        } else {
            return [
                .arc(center: center, radius: radius, startAngle: .pi, endAngle: 0, isCCW: false),
                .arc(center: center, radius: radius, startAngle: 2 * .pi, endAngle: .pi, isCCW: false)
            ]
        }
    }

    // MARK: - Waypoint assembly

    /// Wraps the chained ring stack with an entry move honoring `entry`, then traces the
    /// geometry and retracts -- same three-phase shape `.pocket`'s own
    /// `buildPocketWaypoints` uses, just self-contained here rather than shared, matching
    /// this codebase's existing convention of one private waypoint-assembly function per
    /// operation file (`buildProfileWaypoints`, `buildPocketWaypoints`,
    /// `buildSlottingWaypoints`, ...).
    ///
    /// `.plunge` is exactly the existing straight-down wrapper (`buildWaypoints`).
    /// `.ramp`/`.helix` are the same thin reuse of `RampTools` every other multi-pass
    /// operation makes, covering only this pass's own fresh stepdown (`previousZ` -> `z`).
    /// `.fromOpenEnd` isn't meaningful here -- a counterbore recess has no open end to
    /// feed in from -- so it falls back to a plain vertical plunge rather than leaving a
    /// discontinuous jump straight into the traced ring geometry.
    ///
    /// `boundary` is the recess's own outermost (wall) ring -- every ring here shares the
    /// same center and winding, so any one of them would answer the helix's signed-offset
    /// question the same way; the outermost is used simply because it's always present,
    /// even for a single-ring counterbore.
    private func buildCounterboreWaypoints(for segments: [SC.Segment],
                                           boundary: [SC.Segment],
                                           atZ z: Double,
                                           previousZ: Double,
                                           settings: SC.MachineSettings,
                                           entry: SC.EntryStrategy,
                                           center: CGPoint) -> [SC.Waypoint] {

        // Not converted to `throws` in Step 6.5: `buildCounterboreToolpath` already
        // throws `SC.Error.geometryCollapsed` before ever calling this function if
        // `toolpathSegments` came back empty, so `segments` is guaranteed non-empty on
        // every real call path. Kept as a guarded `return []` rather than a force-unwrap
        // for the same reason as `counterboreRings`' own unreachable guard above --
        // defends a private helper's own contract without assuming a caller's check will
        // never change out from under it, without pretending this is a *new* error a
        // caller here needs to catch.
        guard let firstSegment = segments.first else {
            return []
        }

        let startPoint = firstSegment.startPoint
        let startTangent = direction(of: firstSegment, atEnd: false)

        // `.plunge` rapids and plunges straight down through the hole's own marked
        // `center`, not the first ring's start point -- unlike every other entry
        // strategy below, whose rapid target *is* the first ring's start point,
        // because a plunge is meant to land exactly where the hole itself is marked,
        // matching a drill-style straight-down entry (and how the input point itself
        // reads on screen). It then feeds out to the first ring's start before the
        // trace step below picks up the ring stack -- not a second plunge there, just
        // a normal-feed linear move, since the center itself is already fully swept
        // once the first ring engages (see `counterboreRings`' own doc comment on why
        // the first ring's radius is capped at `toolRadius`).
        guard entry != .plunge else {
            var waypoints: [SC.Waypoint] = [
                SC.Waypoint(position: SIMD3(center.x, center.y, settings.safeZ), motion: .rapid, feedRate: settings.cutting.feedRate),
                SC.Waypoint(position: SIMD3(center.x, center.y, z), motion: .linear, feedRate: settings.cutting.plungeRate),
                SC.Waypoint(position: SIMD3(startPoint.x, startPoint.y, z), motion: .linear, feedRate: settings.cutting.feedRate)
            ]
            waypoints.append(contentsOf: traceRingWaypoints(for: segments, atZ: z, settings: settings))
            return waypoints
        }

        var waypoints: [SC.Waypoint] = [
            SC.Waypoint(position: SIMD3(startPoint.x, startPoint.y, settings.safeZ),
                        motion: .rapid,
                        feedRate: settings.cutting.feedRate)
        ]

        switch entry {
            case .plunge:
                break // Handled above, before this switch.

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

            case .fromOpenEnd:
                // No open end on a counterbore recess -- fall back to a plain plunge
                // rather than leaving the trace below start from a discontinuous jump.
                waypoints.append(
                    SC.Waypoint(position: SIMD3(startPoint.x, startPoint.y, z), motion: .linear, feedRate: settings.cutting.plungeRate)
                )
        }

        waypoints.append(contentsOf: traceRingWaypoints(for: segments, atZ: z, settings: settings))

        return waypoints
    }

    /// Traces the chained ring geometry at `z` and retracts to `safeZ` afterward --
    /// mirrors `buildWaypoints`' own trace + retract steps, pulled out here so both
    /// the `.plunge` branch above (entering at `center`) and every other entry
    /// strategy (entering at the first ring's own start point) share the same
    /// tracing code instead of duplicating it.
    private func traceRingWaypoints(for segments: [SC.Segment], atZ z: Double, settings: SC.MachineSettings) -> [SC.Waypoint] {
        var waypoints: [SC.Waypoint] = []

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
}
