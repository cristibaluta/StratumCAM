//
//  SCEngine+Pocketing.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// Builds the first boundary ring for `.pocket`.
    ///
    /// The pocket boundary is the source contour offset inward by the tool radius.
    /// Travel direction is oriented first so the existing offset engine resolves the
    /// inward offset consistently for climb and conventional milling.
    ///
    /// Step 2.1 intentionally generates one ring at `targetDepth`. Repeated stepover
    /// rings, entry strategies, and Z stepdown are added by later pocketing steps.
    func buildPocketToolpath(for contour: SC.Contour,
                             tool: SC.ToolParams,
                             settings: SC.MachineSettings,
                             direction: SC.CutDirection,
                             pocketType: SC.PocketType,
                             entry: SC.EntryStrategy,
                             strategy: SC.Strategy) -> SC.OutputToolpath? {

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

        // 2. Offset inward by the tool radius using the existing offset engine.
        let toolpathSegments = offsetContour(oriented,
                                             side: .inside,
                                             toolRadius: tool.diameter / 2.0,
                                             isClosed: true)
        guard !toolpathSegments.isEmpty else {
            return nil
        }

        // 3. Step 2.1 is deliberately a single-ring proof of concept. Z stepdown and
        // pocket entry are separate roadmap steps, so use one pass at targetDepth and
        // the shared contour waypoint builder's simple plunge/retract behavior.
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
}
