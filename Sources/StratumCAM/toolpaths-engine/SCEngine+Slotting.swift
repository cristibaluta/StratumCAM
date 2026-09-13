//
//  SCEngine+Slotting.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// Step 2B.1: the basic `.slotting` toolpath -- follows the contour's centerline
    /// directly at cutter-center, no tool-radius offset, since a slot cuts full width
    /// on the curve itself rather than compensating to one side of it the way
    /// `.contour` does (see `CutSide.onContour`'s own doc comment, which describes
    /// exactly this "slotting grooves" case). Reuses `linearize` + `buildWaypoints`
    /// unchanged -- the same rapid/plunge/trace/retract wrapper `.engrave` already
    /// gets via `buildContourTracingToolpath`, just at `depthPerPass` instead of a
    /// `calculateZPasses` stepdown to `settings.targetDepth`.
    ///
    /// Single `ToolpathPass` at `-abs(depthPerPass)` -- this step is explicitly the
    /// "no entry" basic cut per the roadmap's own step title, so there's no ramp/helix
    /// branch here and no multi-pass stepdown down to a total target depth yet either;
    /// both are Step 2B.2's job (multi-pass `depthPerPass` increments down to target
    /// depth, plus wiring `entry` for the first pass's start point, reusing
    /// `rampWaypoints`/`helixEntryWaypoints` the way `.contour`/`.pocket` already do).
    /// `entry` is accepted by the `.slotting` case in `SCEngine`'s switch already (it's
    /// part of the existing `MachiningOperation.slotting` model) but isn't read here --
    /// every pass is a plain straight-down plunge via `buildWaypoints` until 2B.2 wires
    /// it in.
    func buildSlottingToolpath(for contour: SC.Contour,
                               tool: SC.ToolParams,
                               settings: SC.MachineSettings,
                               depthPerPass: Double,
                               operation: SC.MachiningOperation) -> SC.OutputToolpath? {

        let segments = linearize(contour: contour)
        guard !segments.isEmpty else {
            return nil
        }

        let z = -abs(depthPerPass)
        let waypoints = buildWaypoints(for: segments, atZ: z, settings: settings)

        let pass = SC.ToolpathPass(passIndex: 0, depthZ: z, waypoints: waypoints)
        return SC.OutputToolpath(operation: operation, tool: tool, settings: settings, passes: [pass])
    }
}
