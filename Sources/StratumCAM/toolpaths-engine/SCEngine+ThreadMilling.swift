//
//  SCEngine+threadMilling.swift
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
    /// threadMilling operation mills threads onto.
    ///
    /// Unlike `drillPoint(for:)`, a bare `.point` marker isn't accepted here -- threadMilling
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

    /// Builds a thread-milling toolpath: a continuous helix stepping *up* by `pitch`
    /// per full revolution, cutting from the bottom of the thread to the top, around
    /// the nominal diameter drawn in `contour`.
    ///
    /// Real thread milling cuts bottom-to-top, not top-to-bottom, and enters/exits
    /// through the hole's/boss's own center rather than at the cutting radius:
    ///  - Rapid down the center first, straight to the bottom of the thread -- safe
    ///    because the center is unobstructed (a pre-drilled hole or turned boss is
    ///    already clear there, unlike the mill radius itself which stays engaged in
    ///    material for the whole rest of the cut).
    ///  - Feed sideways, once, to engage the wall at the mill radius, at the bottom.
    ///  - Helix upward, one revolution per `pitch`, cutting the thread from the
    ///    bottom up so chips fall clear instead of packing into the thread above.
    ///  - One flat closing lap at the top to clean up the last thread crest.
    ///  - Feed back to center to disengage, *then* retract straight up.
    /// Getting the exit wrong here doesn't just look odd -- retracting straight up
    /// from the cutting radius would drag the tool back through the thread it just
    /// cut, at full engagement, destroying it. Disengaging to center first is what
    /// makes the final retract actually safe.
    ///
    /// Step 2D.1 built the helical core itself, including the offset-sign difference
    /// `isInternal` requires (an internal thread's mill radius eats *inward* from the
    /// drawn diameter, the same direction an `.inside` profile cut offsets; an external
    /// thread's mill radius sits *outward* from it, like `.outside`). Step 2D.2 wires
    /// `direction` (climb/conventional) into which way the helix actually winds, using
    /// the exact same convention `orientedForDirection` already establishes for wall
    /// cuts in `SCEngine+Contour.swift`: an internal thread is cut on the *inside* wall
    /// of the hole, so it follows `.inside`'s own climb/conventional mapping (climb ->
    /// CW, conventional -> CCW); an external thread is cut on the *outside* of the
    /// boss, so it follows `.outside`'s mapping instead (climb -> CCW, conventional ->
    /// CW). Direction is independent of which end the helix starts from, so this
    /// bottom-to-top rework doesn't change either mapping.
    ///
    /// Radial passes, one `ToolpathPass` per pass -- unlike `buildBoringToolpath`/
    /// `buildDrillingToolpath`'s single pass, a thread mill can't take the full
    /// radial engagement in one lap around the helix without risking breakage, so
    /// each pass here retraces the whole bottom-to-top helix at its own,
    /// progressively larger radial engagement (see `threadMillingPassRadius`).
    /// The helix's own per-revolution stepdown, by contrast, stays internal motion
    /// shared by every pass -- not the 2D-geometry Z stepdown `calculateZPasses` is
    /// for at the per-pass level (it's reused here purely to derive per-revolution
    /// depths, the same way `peckDrillingWaypoints` reuses it to derive per-peck
    /// depths).
    func buildThreadMillingToolpath(for contour: SC.Contour,
                                    tool: SC.ToolParams,
                                    settings: SC.MachineSettings,
                                    pitch: Double,
                                    isInternal: Bool,
                                    direction: SC.CutDirection,
                                    radialPasses: Int,
                                    operation: SC.MachiningOperation) -> SC.OutputToolpath? {

        guard radialPasses >= 1 else {
            return nil
        }

        guard let hole = tapCircle(for: contour) else {
            return nil
        }

        let toolRadius = tool.diameter / 2.0
        let holeRadius = hole.diameter / 2.0

        // Internal threading (a pre-drilled hole) cuts on the inside of the drawn
        // diameter -- the mill's own radius eats inward from it, same direction an
        // `.inside` profile cut offsets. External threading is the mirror
        // image: the mill orbits outside the drawn diameter, like `.outside`.
        // This is the *finished* radius -- the one the final radial pass lands on.
        let finalMillRadius = isInternal ? (holeRadius - toolRadius) : (holeRadius + toolRadius)
        guard finalMillRadius > 1e-6 else {
            // Tool doesn't fit -- e.g. thread-milling a hole not much bigger than the
            // tool itself. Mirrors `Segment.offset(by:)`'s own "tool doesn't fit" guard.
            return nil
        }

        let pitchMagnitude = abs(pitch)
        guard pitchMagnitude > 1e-9 else {
            return nil
        }

        // Reuse `calculateZPasses` exactly the way `peckDrillingWaypoints` already does
        // (feeding a per-cycle increment in place of a Z-stepdown) -- `pitch` in place
        // of `stepdown` gives one target depth per full revolution, top-to-bottom, e.g.
        // [-1, -2, -3] for a 3mm-deep, 1mm-pitch thread, complete with the same
        // fencepost-safe rounding so an evenly-divisible depth/pitch pair doesn't gain a
        // spurious extra turn (and an unevenly-divisible one gets its odd leftover
        // turn placed at the true target depth, i.e. the very bottom).
        //
        // The cut itself runs the other way -- bottom to top -- so these get flipped
        // into a bottom-to-top boundary list: prepend the top (Z=0), reverse it, and
        // walk consecutive pairs as (fromZ, toZ) for each ascending turn. E.g.
        // [0, -1, -2, -3] reversed is [-3, -2, -1, 0]: start at the bottom, finish at
        // the top, and the odd leftover turn (if any) lands as the very first,
        // shortest turn off the bottom rather than the last one off the top.
        let turnDepths = calculateZPasses(targetDepth: settings.targetDepth, stepdown: pitchMagnitude)
        let boundaries = Array(([0.0] + turnDepths).reversed())
        let bottomZ = boundaries.first ?? 0.0

        let center = hole.center

        // Same climb/conventional convention `orientedForDirection` uses for wall cuts:
        // internal threading cuts the *inside* wall of the hole (like `.inside`, where
        // climb requires CW travel), external threading cuts the *outside* of the boss
        // (like `.outside`, where climb requires CCW travel).
        let isCCW = isInternal ? (direction == .conventional) : (direction == .climb)
        let stepsPerTurn = 8
        let sweepPerStep = (2 * Double.pi / Double(stepsPerTurn)) * (isCCW ? 1.0 : -1.0)

        // One full lap of the helix, taken at full radial engagement, is what a
        // thread mill can safely bite off in one go -- more than that risks
        // snapping the tool. So every pass below retraces the *entire* bottom-to-top
        // helix, but at its own radius: pass 0 stays furthest from `finalMillRadius`
        // (lightest cut) and each subsequent pass steps closer, with the last pass
        // (index `radialPasses - 1`) landing exactly on `finalMillRadius` -- the true
        // thread size. See `threadMillingPassRadius` for how that radius is derived.
        let passes: [SC.ToolpathPass] = (0..<radialPasses).map { passIndex in
            let radius = threadMillingPassRadius(passIndex: passIndex,
                                                 radialPasses: radialPasses,
                                                 finalMillRadius: finalMillRadius,
                                                 toolRadius: toolRadius,
                                                 isInternal: isInternal)

            let waypoints = threadMillingPassWaypoints(center: center,
                                                       radius: radius,
                                                       bottomZ: bottomZ,
                                                       boundaries: boundaries,
                                                       sweepPerStep: sweepPerStep,
                                                       stepsPerTurn: stepsPerTurn,
                                                       settings: settings)

            return SC.ToolpathPass(passIndex: passIndex, depthZ: bottomZ, waypoints: waypoints)
        }

        return SC.OutputToolpath(operation: operation, tool: tool, settings: settings, passes: passes)
    }

    /// Radial engagement for one thread-milling pass, stepping from a conservative
    /// first pass out to the true thread size on the last one.
    ///
    /// `toolRadius` doubles as the natural scale for "how conservative": at zero
    /// engagement the tool's cutting edge would sit exactly on the nominal thread
    /// diameter without removing anything, which happens when the toolpath radius
    /// is a full `toolRadius` short of `finalMillRadius`'s own offset. Passes step
    /// that shortfall down linearly to zero, e.g. for 3 passes the cutting edge
    /// reaches 1/3, 2/3, then the full nominal diameter.
    ///
    /// Internal and external threads step in opposite directions for the same
    /// reason `finalMillRadius` itself is computed with opposite signs: an internal
    /// thread's cutting edge approaches the wall from inside (radius grows outward,
    /// toward `finalMillRadius`), an external thread's approaches the boss from
    /// outside (radius shrinks inward, toward `finalMillRadius`).
    private func threadMillingPassRadius(passIndex: Int,
                                         radialPasses: Int,
                                         finalMillRadius: Double,
                                         toolRadius: Double,
                                         isInternal: Bool) -> Double {
        let fraction = Double(passIndex + 1) / Double(radialPasses)
        let shortfall = toolRadius * (1.0 - fraction)
        let radius = isInternal ? (finalMillRadius - shortfall) : (finalMillRadius + shortfall)
        // Guard against a degenerate early pass on a hole/boss barely bigger than
        // the tool -- keeps every pass a valid, positive radius even though only
        // `finalMillRadius` itself is checked against the tool-fits-at-all guard
        // above.
        return max(radius, 1e-6)
    }

    /// Builds one radial pass's full set of waypoints: rapid to center, straight
    /// down to the bottom, feed out to `radius` to engage, helix bottom-to-top
    /// through every boundary in `boundaries` plus a flat closing lap at the top,
    /// then disengage back to center before retracting -- the same enter/cut/exit
    /// shape `buildThreadMillingToolpath`'s doc comment describes, just parameterized
    /// on radius so it can be reused for every radial pass, roughing or finishing.
    private func threadMillingPassWaypoints(center: CGPoint,
                                            radius: Double,
                                            bottomZ: Double,
                                            boundaries: [Double],
                                            sweepPerStep: Double,
                                            stepsPerTurn: Int,
                                            settings: SC.MachineSettings) -> [SC.Waypoint] {

        // The wall-engagement point, always the hole's/boss's own 3 o'clock position --
        // same convention `buildBoringToolpath` uses for its circular interpolation.
        let engagePoint = CGPoint(x: center.x + radius, y: center.y)

        var waypoints: [SC.Waypoint] = [
            SC.Waypoint(position: SIMD3(center.x, center.y, settings.safeZ), motion: .rapid, feedRate: settings.cutting.feedRate),
            // Rapid straight down the center to the bottom of the thread -- clear of
            // any wall the whole way down.
            SC.Waypoint(position: SIMD3(center.x, center.y, bottomZ), motion: .rapid, feedRate: settings.cutting.feedRate),
            // Feed sideways to engage the wall at this pass's radius -- only once, at
            // the bottom, right before cutting starts.
            SC.Waypoint(position: SIMD3(engagePoint.x, engagePoint.y, bottomZ), motion: .linear, feedRate: settings.cutting.feedRate)
        ]

        var previousZ = bottomZ
        for nextZ in boundaries.dropFirst() {
            waypoints.append(
                contentsOf: threadTurnWaypoints(center: center,
                                                radius: radius,
                                                fromZ: previousZ,
                                                toZ: nextZ,
                                                sweepPerStep: sweepPerStep,
                                                stepsPerTurn: stepsPerTurn,
                                                settings: settings)
            )
            previousZ = nextZ
        }

        // Finish with one flat lap at the top to clean up the last thread crest --
        // the same "flat pass" convention flagged for helical boring (Step 2C.4's
        // roadmap note), landed for real here since the helix *is* the whole cut
        // rather than just an entry move down to a separate trace.
        waypoints.append(
            contentsOf: threadTurnWaypoints(center: center,
                                            radius: radius,
                                            fromZ: previousZ,
                                            toZ: previousZ,
                                            sweepPerStep: sweepPerStep,
                                            stepsPerTurn: stepsPerTurn,
                                            settings: settings)
        )

        // Disengage back to center before retracting -- this is what keeps the
        // retract from dragging the tool back across the thread it just cut.
        waypoints.append(
            SC.Waypoint(position: SIMD3(center.x, center.y, previousZ), motion: .linear, feedRate: settings.cutting.feedRate)
        )
        waypoints.append(
            SC.Waypoint(position: SIMD3(center.x, center.y, settings.safeZ), motion: .rapid, feedRate: settings.cutting.feedRate)
        )

        return waypoints
    }

    /// One full revolution of the thread-milling helix, tessellated into `stepsPerTurn`
    /// arc waypoints stepping the tool from `fromZ` to `toZ` -- the same tessellation
    /// convention `helixEntryWaypoints` uses for its own circular entry move, just
    /// carried through the entire cut here rather than a short hop down to a contour's
    /// start point. Works ascending or descending: `fromZ`/`toZ` just set the per-step
    /// increment's sign. Passing `fromZ == toZ` produces a flat lap at constant depth
    /// (used for the closing lap at the top of the thread).
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
