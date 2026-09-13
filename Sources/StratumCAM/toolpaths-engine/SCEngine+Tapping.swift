//
//  SCEngine+Tapping.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation
import CoreGraphics
import SwiftDXF
import simd

extension SCEngine {

    /// Extracts the hole (internal thread) or boss (external thread) circle that a
    /// tapping operation mills threads onto.
    ///
    /// Unlike `drillPoint(for:)`, a bare `.point` marker isn't accepted here -- tapping
    /// needs an actual diameter to compensate the tool radius against, and a point alone
    /// carries no size. Only a single closed `.circle` entity is recognized, the same
    /// "closed circle marks a feature" convention `drillPoint(for:)` already uses for
    /// hole centers, just carrying the radius through instead of discarding it.
    func tapCircle(for contour: SC.Contour) -> (center: CGPoint, diameter: Double)? {
        guard contour.entities.count == 1, contour.isClosed else {
            return nil
        }

        guard case let .circle(center, radius, _, _) = contour.entities[0].entity else {
            return nil
        }

        return (center.cgPoint, radius * 2.0)
    }

    /// Builds a thread-milling toolpath: a continuous helix stepping down by `pitch`
    /// per full revolution around the nominal diameter drawn in `contour`, finishing
    /// with one flat lap at full depth to clean up the last thread crest, then a
    /// retract to Safe Z.
    ///
    /// This is Step 2D.1's scope -- the helical core itself, including the offset-sign
    /// difference `isInternal` requires (an internal thread's mill radius eats *inward*
    /// from the drawn diameter, the same direction an `.inside` profile cut offsets;
    /// an external thread's mill radius sits *outward* from it, like `.outside`) since
    /// the geometry has no sensible single-radius fallback without deciding that. What
    /// Step 2D.1 does *not* do yet is wire `direction` (climb/conventional) into which
    /// way the helix winds -- that's Step 2D.2, per the roadmap's own split -- so the
    /// winding sense here is always CCW regardless of `direction`, the same "accepted
    /// but not yet wired" flag `.trochoidal`'s own `TrochoidalSettings` carries for a
    /// different parameter (see Step 1B.2's flag in `SCEngine+Pocketing.swift`).
    ///
    /// One `ToolpathPass`, same reasoning `buildBoringToolpath`/`buildDrillingToolpath`
    /// use -- the helix's own per-revolution stepdown is internal motion within a single
    /// hole/boss, not the 2D-geometry Z stepdown `calculateZPasses` is for at the
    /// per-pass level (it's reused here purely to derive per-revolution depths, the same
    /// way `peckDrillingWaypoints` reuses it to derive per-peck depths).
    func buildTappingToolpath(for contour: SC.Contour,
                              tool: SC.ToolParams,
                              settings: SC.MachineSettings,
                              pitch: Double,
                              isInternal: Bool,
                              direction: SC.CutDirection,
                              operation: SC.MachiningOperation) -> SC.OutputToolpath? {

        guard let hole = tapCircle(for: contour) else {
            return nil
        }

        let toolRadius = tool.diameter / 2.0
        let holeRadius = hole.diameter / 2.0

        // Internal threading (a pre-drilled hole) cuts on the inside of the drawn
        // diameter -- the mill's own radius eats inward from it, same direction an
        // `.inside` profile cut offsets. External threading (a boss) is the mirror
        // image: the mill orbits outside the drawn diameter, like `.outside`.
        let millRadius = isInternal ? (holeRadius - toolRadius) : (holeRadius + toolRadius)
        guard millRadius > 1e-6 else {
            // Tool doesn't fit -- e.g. thread-milling a hole not much bigger than the
            // tool itself. Mirrors `Segment.offset(by:)`'s own "tool doesn't fit" guard.
            return nil
        }

        let pitchMagnitude = abs(pitch)
        guard pitchMagnitude > 1e-9 else {
            return nil
        }

        // Reuse `calculateZPasses` exactly the way `peckDrillingWaypoints` already does
        // (feeding a per-cycle increment in place of a Z-stepdown) -- here `pitch` in
        // place of `stepdown` gives one target depth per full revolution, complete with
        // the same fencepost-safe rounding so an evenly-divisible depth/pitch pair
        // doesn't gain a spurious extra turn.
        let turnDepths = calculateZPasses(targetDepth: settings.targetDepth, stepdown: pitchMagnitude)

        // Start (and, each revolution, return to) the hole's own 3 o'clock position --
        // same convention `buildBoringToolpath` uses for its circular interpolation.
        let start = CGPoint(x: hole.center.x + millRadius, y: hole.center.y)

        var waypoints: [SC.Waypoint] = [
            SC.Waypoint(position: SIMD3(start.x, start.y, settings.safeZ), motion: .rapid, feedRate: settings.cutting.feedRate),
            // Rapid down to the top of stock at the mill radius -- safe because that
            // radius sits inside an already-drilled hole (internal) or clear outside an
            // already-turned boss (external), the same "no material in the way" reasoning
            // `buildProfileWaypoints`'s ramp/helix entry relies on for its own rapid
            // down to `previousZ` before descending.
            SC.Waypoint(position: SIMD3(start.x, start.y, 0), motion: .rapid, feedRate: settings.cutting.feedRate)
        ]

        let stepsPerTurn = 8
        let isCCW = true // Step 2D.2 wires `direction` into this; always CCW for now.
        let sweepPerStep = (2 * Double.pi / Double(stepsPerTurn)) * (isCCW ? 1.0 : -1.0)

        var previousZ = 0.0
        for depth in turnDepths {
            waypoints.append(
                contentsOf: threadTurnWaypoints(center: hole.center,
                                                radius: millRadius,
                                                fromZ: previousZ,
                                                toZ: depth,
                                                sweepPerStep: sweepPerStep,
                                                stepsPerTurn: stepsPerTurn,
                                                settings: settings)
            )
            previousZ = depth
        }

        // Finish with one flat lap at full depth to clean up the last thread crest --
        // the same "flat pass at the bottom" convention flagged for helical boring
        // (Step 2C.4's roadmap note), landed for real here since the helix *is* the
        // whole cut rather than just an entry move down to a separate trace.
        waypoints.append(
            contentsOf: threadTurnWaypoints(center: hole.center,
                                            radius: millRadius,
                                            fromZ: previousZ,
                                            toZ: previousZ,
                                            sweepPerStep: sweepPerStep,
                                            stepsPerTurn: stepsPerTurn,
                                            settings: settings)
        )

        waypoints.append(
            SC.Waypoint(position: SIMD3(start.x, start.y, settings.safeZ), motion: .rapid, feedRate: settings.cutting.feedRate)
        )

        let pass = SC.ToolpathPass(passIndex: 0, depthZ: previousZ, waypoints: waypoints)
        return SC.OutputToolpath(operation: operation, tool: tool, settings: settings, passes: [pass])
    }

    /// One full revolution of the thread-milling helix, tessellated into `stepsPerTurn`
    /// arc waypoints stepping the tool from `fromZ` to `toZ` -- the same tessellation
    /// convention `helixEntryWaypoints` uses for its own circular entry move, just
    /// carried through the entire cut here rather than a short hop down to a contour's
    /// start point. Passing `fromZ == toZ` produces a flat lap at constant depth (used
    /// for the closing lap at the bottom of the thread).
    private func threadTurnWaypoints(center: CGPoint,
                                     radius: Double,
                                     fromZ: Double,
                                     toZ: Double,
                                     sweepPerStep: Double,
                                     stepsPerTurn: Int,
                                     settings: SC.MachineSettings) -> [SC.Waypoint] {

        let dropPerStep = (fromZ - toZ) / Double(stepsPerTurn)
        let isCCW = sweepPerStep > 0

        var waypoints: [SC.Waypoint] = []
        var currentZ = fromZ
        for step in 1...stepsPerTurn {
            let angle = sweepPerStep * Double(step)
            currentZ = (step == stepsPerTurn) ? toZ : currentZ - dropPerStep
            let x = center.x + radius * cos(angle)
            let y = center.y + radius * sin(angle)
            waypoints.append(
                SC.Waypoint(position: SIMD3(x, y, currentZ),
                            motion: isCCW ? .arcCCW(center: center) : .arcCW(center: center),
                            feedRate: settings.cutting.feedRate)
            )
        }
        return waypoints
    }
}
