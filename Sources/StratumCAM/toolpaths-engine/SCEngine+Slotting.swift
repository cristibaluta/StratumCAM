//
//  SCEngine+Slotting.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation
import CoreGraphics

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
}
