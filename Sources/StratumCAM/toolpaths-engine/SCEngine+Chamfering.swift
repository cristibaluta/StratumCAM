//
//  SCEngine+Chamfering.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// Chamfering always machines in a single pass at a depth derived from the desired
    /// bevel width and the tool's V-bit angle (unless an explicit depth is given) --
    /// stepping down in multiple passes would just keep widening the bevel and gouge the part.
    ///
    /// Throws (Step 6.3, same pattern `buildDrillingToolpath` established in 6.2) rather
    /// than returning `nil` for either of its two failure sites: `SC.Error.toolIncompatible`
    /// when the tool can't resolve a chamfer depth (not a V-bit, or missing `vAngle` with no
    /// explicit depth given), and `SC.Error.invalidContour` when the contour has no usable
    /// geometry to chamfer at all.
    func buildChamferToolpath(for contour: SC.Contour,
                              tool: SC.ToolParams,
                              settings: SC.MachineSettings,
                              params: SC.ChamferParams,
                              operation: SC.MachiningOperation) throws -> SC.OutputToolpath {

        guard let z = params.resolvedDepth(for: tool) else {
            // Misconfigured tool (not a V-bit, or missing vAngle with no explicit depth) --
            // bail out rather than cut at a made-up depth.
            throw SC.Error.toolIncompatible
        }

        let baseSegments = contour.linearizedSegments
        guard !baseSegments.isEmpty else {
            throw SC.Error.invalidContour
        }

        // Orient the chain so travel direction matches the requested climb/conventional
        // cut, same as `.contour` -- reuses the existing helper rather than duplicating
        // the winding logic here.
        let oriented = orientedForDirection(baseSegments, side: params.side, direction: params.direction)

        // The bevel's horizontal reach at the resolved depth is what we offset the
        // centerline path by, same corner-fillet/trim machinery as a profile cut.
        let horizontalReach = abs(z) * tan(((tool.vAngle ?? 0) / 2.0).degreesToRadians)
        let toolpathSegments = offsetContour(oriented,
                                             side: params.side,
                                             toolRadius: horizontalReach,
                                             isClosed: contour.isClosed)

        let waypoints = buildWaypoints(for: toolpathSegments, atZ: z, settings: settings)
        let pass = SC.ToolpathPass(passIndex: 0, depthZ: z, waypoints: waypoints)

        return SC.OutputToolpath(operation: operation, tool: tool, settings: settings, passes: [pass])
    }
}
