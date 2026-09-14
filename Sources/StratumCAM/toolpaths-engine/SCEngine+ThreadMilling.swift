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

    /// Extracts the *existing* hole (internal thread) or boss (external thread) circle
    /// that a threadMilling operation starts from -- the geometry the person actually
    /// selects in the CAM software, e.g. an already-drilled 2.5mm pilot hole. This is
    /// deliberately not the finished thread diameter; that's `targetDiameter` on the
    /// `.threadMilling` operation itself, since the finished size isn't something drawn
    /// in CAD, it's a property of the thread being cut.
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
    /// per full revolution, cutting from the bottom of the thread to the top, working
    /// outward/inward from the existing hole/boss diameter drawn in `contour` toward
    /// `targetDiameter`, the finished thread size.
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
    /// `direction` -- the thread's own handedness, right-hand or left-hand -- into
    /// which way the helix actually winds. This is *not* a climb/conventional choice:
    /// climb/conventional is meaningless here because nothing about a thread mill's
    /// winding sense is free to pick for chip load -- a right-hand thread only winds
    /// one way, full stop, and cutting it the other way produces a left-hand thread
    /// instead (or, at full radial engagement, just breaks the tool). Handedness is
    /// also independent of `isInternal`: a right-hand nut only ever mates with a
    /// right-hand bolt, so internal and external threads of the same handedness wind
    /// the same way, not mirrored. Since the cut always runs bottom-to-top (see
    /// above), the mapping is fixed: a right-hand thread sweeps counterclockwise
    /// (viewed from above, i.e. looking down the +Z axis) as it climbs, a left-hand
    /// thread sweeps clockwise. Direction is independent of which end the helix
    /// starts from, so this bottom-to-top rework doesn't change that mapping.
    ///
    /// Radial passes, one `ToolpathPass` per pass -- unlike `buildBoringToolpath`/
    /// `buildDrillingToolpath`'s single pass, a thread mill can't jump straight from
    /// the existing hole/boss diameter to the finished thread diameter in one lap
    /// around the helix without risking breakage, so each pass here retraces the
    /// whole bottom-to-top helix at its own, progressively larger (internal) or
    /// smaller (external) working diameter, stepped evenly from the existing
    /// diameter to `targetDiameter` (see `threadMillingPassRadius`). The helix's own
    /// per-revolution stepdown, by contrast, stays internal motion shared by every
    /// pass -- not the 2D-geometry Z stepdown `calculateZPasses` is for at the
    /// per-pass level (it's reused here purely to derive per-revolution depths, the
    /// same way `peckDrillingWaypoints` reuses it to derive per-peck depths).
    func buildThreadMillingToolpath(for contour: SC.Contour,
                                    tool: SC.ToolParams,
                                    settings: SC.MachineSettings,
                                    pitch: Double,
                                    isInternal: Bool,
                                    direction: SC.ThreadDirection,
                                    radialPasses: Int,
                                    targetDiameter: Double,
                                    operation: SC.MachiningOperation) -> SC.OutputToolpath? {

        guard radialPasses >= 1 else {
            return nil
        }

        guard let hole = tapCircle(for: contour) else {
            return nil
        }

        let toolRadius = tool.diameter / 2.0
        let existingDiameter = hole.diameter

        // Internal threading (a pre-drilled hole) cuts on the inside of the target
        // diameter -- the mill's own radius eats inward from it, same direction an
        // `.inside` profile cut offsets. External threading is the mirror
        // image: the mill orbits outside the target diameter, like `.outside`.
        // This is the *finished* radius -- the one the final radial pass lands on.
        let finalMillRadius = isInternal ? (targetDiameter / 2.0 - toolRadius) : (targetDiameter / 2.0 + toolRadius)
        guard finalMillRadius > 1e-6 else {
            // Tool doesn't fit -- e.g. thread-milling down to a target diameter not
            // much bigger than the tool itself. Mirrors `Segment.offset(by:)`'s own
            // "tool doesn't fit" guard.
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
        let turnDepths = EngineTools.calculateZPasses(targetDepth: settings.targetDepth, stepdown: pitchMagnitude)
        let boundaries = Array(([0.0] + turnDepths).reversed())
        let bottomZ = boundaries.first ?? 0.0

        let center = hole.center

        // Winding sense is dictated purely by thread handedness, not by isInternal --
        // a right-hand nut only ever mates with a right-hand bolt, so internal and
        // external threads of the same handedness wind the same way. Since the cut
        // always runs bottom-to-top, a right-hand thread sweeps counterclockwise
        // (viewed from above) as it climbs; a left-hand thread sweeps clockwise.
        let isCCW = direction == .rightHand
        let stepsPerTurn = 8
        let sweepPerStep = (2 * Double.pi / Double(stepsPerTurn)) * (isCCW ? 1.0 : -1.0)

        // Jumping straight from the existing diameter to the finished thread size in
        // one lap around the helix is what risks snapping the tool. So every pass
        // below retraces the *entire* bottom-to-top helix, but at its own working
        // diameter: pass 0 sits closest to the existing (already-drilled/turned)
        // diameter and each subsequent pass steps toward `targetDiameter`, with the
        // last pass (index `radialPasses - 1`) landing exactly on it. See
        // `threadMillingPassRadius` for how that radius is derived.
        let passes: [SC.ToolpathPass] = (0..<radialPasses).map { passIndex in
            let radius = threadMillingPassRadius(passIndex: passIndex,
                                                 radialPasses: radialPasses,
                                                 existingDiameter: existingDiameter,
                                                 targetDiameter: targetDiameter,
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

    /// Radial engagement for one thread-milling pass: the working *diameter* steps
    /// evenly from `existingDiameter` (the hole/boss as it already exists, selected
    /// in the CAM software) to `targetDiameter` (the finished thread size) over
    /// `radialPasses` passes, e.g. for an M3's 2.5mm pilot hole stepping to a 3.0mm
    /// major diameter in 3 passes: step = (3.0 - 2.5) / 3 = 0.1667mm, so the passes'
    /// working diameters are 2.667, 2.833, then exactly 3.0 on the last pass.
    ///
    /// Each pass's working diameter is then compensated for the tool radius the
    /// same way `finalMillRadius` is: an internal thread's cutting edge approaches
    /// that pass's wall from inside (mill radius = workingRadius - toolRadius), an
    /// external thread's approaches its wall from outside (mill radius =
    /// workingRadius + toolRadius).
    private func threadMillingPassRadius(passIndex: Int,
                                         radialPasses: Int,
                                         existingDiameter: Double,
                                         targetDiameter: Double,
                                         toolRadius: Double,
                                         isInternal: Bool) -> Double {
        let step = (targetDiameter - existingDiameter) / Double(radialPasses)
        // Fencepost-safe: on the last pass (passIndex == radialPasses - 1) this
        // reduces to exactly `targetDiameter`, regardless of rounding, since
        // `existingDiameter + step * radialPasses == targetDiameter` algebraically.
        let workingDiameter = existingDiameter + step * Double(passIndex + 1)
        let workingRadius = workingDiameter / 2.0
        let radius = isInternal ? (workingRadius - toolRadius) : (workingRadius + toolRadius)
        // Guard against a degenerate early pass where the existing diameter is
        // barely bigger than the tool itself -- keeps every pass a valid, positive
        // radius even though only the final pass (via `finalMillRadius`) is checked
        // against the tool-fits-at-all guard above.
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
