//
//  SCEngine+Pocketing.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// Builds the `.offsetPattern` pocket toolpath: a boundary wall ring plus
    /// successive concentric stepover rings, chained into one continuous pass.
    ///
    /// Step 2.1 covered the first ring (the boundary offset). Step 2.2 adds the
    /// stepover ring stack on top of it. Z stepdown and pocket entry (helix/ramp)
    /// are still separate roadmap steps (2.4, 2.5) -- this always plunges/retracts
    /// straight down at `targetDepth` via the shared `buildWaypoints` behavior.
    func buildPocketToolpath(for contour: SC.Contour,
                             tool: SC.ToolParams,
                             settings: SC.MachineSettings,
                             direction: SC.CutDirection,
                             pocketType: SC.PocketType,
                             entry: SC.EntryStrategy,
                             strategy: SC.MachiningOperation) -> SC.OutputToolpath? {

        guard contour.isClosed else {
            return nil
        }

        guard pocketType == .offsetPattern else {
            // Raster clearing is a separate algorithm covered by Step 2.3.
            return nil
        }

        let baseSegments = linearize(contour: contour)
        guard !baseSegments.isEmpty else {
            return nil
        }

        // 1. Orient the chain so travel direction matches the requested cut direction.
        // Pocket walls are inside cuts, so use `.inside` for the same climb/conventional
        // convention already established by profile.
        let oriented = orientedForDirection(baseSegments,
                                            side: .inside,
                                            direction: direction)

        // 2. Generate the concentric ring stack, geometry only (Step 2.2a).
        let rings = pocketRings(from: oriented, tool: tool)
        guard !rings.isEmpty else {
            return nil
        }

        // 3. Chain the rings into one continuous cut path with connecting
        // transitions between them (Step 2.2b), then hand the whole thing to
        // the shared waypoint builder exactly like a single ring would use --
        // it already produces the rapid/plunge/retract wrapper around
        // whatever flat segment chain it's given.
        let toolpathSegments = chainedRingSegments(rings)
        guard !toolpathSegments.isEmpty else {
            return nil
        }

        let z = settings.targetDepth
        let waypoints = buildWaypoints(for: toolpathSegments,
                                       atZ: z,
                                       settings: settings)
        let pass = SC.ToolpathPass(passIndex: 0,
                                   depthZ: z,
                                   waypoints: waypoints)

        return SC.OutputToolpath(strategy: strategy,
                                 tool: tool,
                                 settings: settings,
                                 passes: [pass])
    }

    // MARK: - Step 2.2a: ring geometry

    /// Generates the concentric ring stack for `.offsetPattern` pocketing, geometry
    /// only -- no waypoints yet (that's `chainedRingSegments` + `buildWaypoints`).
    ///
    /// The first ring is the same tool-radius wall offset as Step 2.1. Every ring
    /// after that steps a further `tool.stepoverPercentage * tool.diameter` inward --
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
    func pocketRings(from orientedBoundary: [SC.Segment], tool: SC.ToolParams) -> [[SC.Segment]] {
        let firstRing = offsetContour(orientedBoundary,
                                      side: .inside,
                                      toolRadius: tool.diameter / 2.0,
                                      isClosed: true)
        guard !firstRing.isEmpty else {
            return []
        }

        var rings: [[SC.Segment]] = [firstRing]

        let stepover = tool.stepoverPercentage * tool.diameter
        guard stepover > 1e-6 else {
            // No forward progress possible with a zero/negative stepover -- the
            // boundary ring is all we can offer.
            return rings
        }

        let winding = isCCWWinding(firstRing)
        var current = firstRing

        // Safety cap: `offsetContour`'s collapse signal and the winding-flip
        // check below are expected to end the loop first in every realistic
        // case, but a cap keeps a pathological input from spinning forever.
        let maxRings = 500
        while rings.count < maxRings {
            let next = offsetContour(current, side: .inside, toolRadius: stepover, isClosed: true)

            guard next != current else {
                break // offsetContour's own arc-collapse signal.
            }
            guard isCCWWinding(next) == winding else {
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
    /// the end of each ring and the start of the next.
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
}
