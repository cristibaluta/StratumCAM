//
//  SCEngine+Boring.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation
import CoreGraphics
import simd

extension SCEngine {

    /// Builds a basic boring cycle: rapid to the hole's edge at Safe Z, plunge straight
    /// down to depth, then circular interpolation at `targetDiameter / 2` around the hole
    /// center to open it out to its finished diameter, then retract to Safe Z.
    ///
    /// Closest in shape to drilling -- reuses `drillPoint(for:)` for hole-location
    /// recognition, same point/closed-circle contour shapes drilling accepts -- but unlike
    /// drilling, which plunges and retracts on the hole's own centerline, boring's whole
    /// point is enlarging an existing hole to a precise diameter with a single-point tool,
    /// so the cutting motion happens off-center: the plunge and the circular pass both sit
    /// `targetDiameter / 2` away from `point`, orbiting the bore wall rather than punching
    /// through it.
    ///
    /// The full circle is swept as two 180° arcs rather than one 360° arc, matching
    /// `convert(entity:reversed:)`'s existing DXF-circle handling -- a single arc command
    /// whose start and end position are identical is ambiguous (zero sweep vs. a full
    /// revolution) on many controllers, so it's always split in two here as well, in the
    /// same CCW direction that convert's un-reversed circle case defaults to.
    ///
    /// One `ToolpathPass`, same reasoning as `buildDrillingToolpath` -- a boring cycle's
    /// own bottom-of-hole circular pass isn't the 2D-geometry Z stepdown `calculateZPasses`
    /// is for.
    ///
    /// `dwellTime` isn't handled here -- like drilling's own dwell, it doesn't change the
    /// waypoint geometry at all, just pauses in place, so it's injected purely at G-code
    /// text generation time (`SCGCodeEngine`) rather than as a waypoint in this array. See
    /// that file for where it lands relative to these waypoints.
    ///
    /// `shiftRetract`, by contrast, does change the geometry -- it moves where the retract
    /// actually happens -- so it's handled here, not in the G-code layer.
    func buildBoringToolpath(for contour: SC.Contour,
                             tool: SC.ToolParams,
                             settings: SC.MachineSettings,
                             targetDiameter: Double,
                             shiftRetract: Bool,
                             operation: SC.MachiningOperation) -> SC.OutputToolpath? {

        guard let point = drillPoint(for: contour) else {
            return nil
        }

        let radius = abs(targetDiameter) / 2.0
        let z = -abs(settings.targetDepth)

        // Start/end the circular interpolation at the hole's own 3 o'clock position --
        // same convention `convert(entity:reversed:)` uses for a plain DXF circle -- so
        // the bore's entry/exit point is predictable regardless of `targetDiameter`.
        let start = CGPoint(x: point.x + radius, y: point.y)
        let opposite = CGPoint(x: point.x - radius, y: point.y)

        var waypoints: [SC.Waypoint] = [
            SC.Waypoint(position: SIMD3(start.x, start.y, settings.safeZ), motion: .rapid, feedRate: settings.cutting.feedRate),
            SC.Waypoint(position: SIMD3(start.x, start.y, z), motion: .linear, feedRate: settings.cutting.plungeRate),
            SC.Waypoint(position: SIMD3(opposite.x, opposite.y, z), motion: .arcCCW(center: point), feedRate: settings.cutting.feedRate),
            SC.Waypoint(position: SIMD3(start.x, start.y, z), motion: .arcCCW(center: point), feedRate: settings.cutting.feedRate)
        ]

        // Step 2C.2: shift off the freshly bored wall before retracting, at depth, so the
        // rapid retract that follows doesn't drag the tool's edge straight back across the
        // finished bore -- the reason a plain drill cycle's straight-up retract isn't good
        // enough here. Shifted inward toward `point` by the tool's own radius (clamped so
        // it never overshoots past the hole's center on a bore not much wider than the
        // tool itself), along the same side the circular pass finished on.
        let retractPoint: CGPoint
        if shiftRetract {
            let shiftDistance = min(tool.diameter / 2.0, radius)
            retractPoint = CGPoint(x: start.x - shiftDistance, y: start.y)
            waypoints.append(SC.Waypoint(position: SIMD3(retractPoint.x, retractPoint.y, z), motion: .linear, feedRate: settings.cutting.feedRate))
        } else {
            retractPoint = start
        }

        waypoints.append(SC.Waypoint(position: SIMD3(retractPoint.x, retractPoint.y, settings.safeZ), motion: .rapid, feedRate: settings.cutting.feedRate))

        let pass = SC.ToolpathPass(passIndex: 0, depthZ: z, waypoints: waypoints)
        return SC.OutputToolpath(operation: operation, tool: tool, settings: settings, passes: [pass])
    }
}
