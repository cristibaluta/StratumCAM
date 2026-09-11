//
//  SCEngine+Contour.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// Shared pipeline behind `.engrave` and (for now) `.profile`: linearize the contour,
    /// optionally apply tool-radius compensation, step down through Z, and trace the
    /// resulting segments once per pass. The `strategy` passed in is the one actually
    /// requested by the caller, so the output is tagged accurately instead of hardcoded.
    func buildContourTracingToolpath(for contour: SC.Contour,
                                     tool: SC.ToolParams,
                                     settings: SC.MachineSettings,
                                     side: SC.CutSide,
                                     strategy: SC.Strategy) -> SC.OutputToolpath? {

        // 1. Normalize DXF Entities into linear/arc segments (handling reversed flag)
        let baseSegments = linearize(contour: contour)
        guard !baseSegments.isEmpty else {
            return nil
        }

        // 1b. Apply tool-radius compensation for inside/outside profile cuts
        let toolpathSegments = offsetContour(baseSegments,
                                             side: side,
                                             toolRadius: tool.diameter / 2.0,
                                             isClosed: contour.isClosed)

        // 2. Calculate Z depth passes based on tool stepdown
        let zDepths = calculateZPasses(targetDepth: settings.targetDepth, stepdown: tool.stepdown)

        // 3. Build waypoints per pass
        var passes: [SC.ToolpathPass] = []
        for (i, z) in zDepths.enumerated() {
            let waypoints = buildWaypoints(for: toolpathSegments, atZ: z, settings: settings)
            passes.append(SC.ToolpathPass(passIndex: i, depthZ: z, waypoints: waypoints))
        }

        return SC.OutputToolpath(strategy: strategy, tool: tool, settings: settings, passes: passes)
    }
}
