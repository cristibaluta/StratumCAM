//
//  SCEngine+Chamfering.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// Cuts a bevel with a V-bit's angled flank.
    ///
    /// The tool follows ONE path around the contour, at a fixed XY offset, and only Z changes from
    /// pass to pass. The final pass plunges the tool tip ON the selected contour, so the offset
    /// does not depend on the bevel's size, only on the tool and on `tipOffset` (θ = half the V-bit
    /// angle, t = the tool's tip flat, h0 = `tipOffset`):
    ///
    ///     offset = t/2 + h0 * tan θ
    ///
    /// A sharp tip with no tip offset therefore runs with the tool center exactly on the contour;
    /// a tip flat moves it out by t/2 (the flat's outer corner then touches the edge) and a tip
    /// offset by h0 * tan θ more, in the direction of the tool side.
    ///
    /// The bevel itself lies on the other side of the contour, rising from the edge and running
    /// back toward the part:
    /// - `.bottom` edge (contour = the wall at the bevel's lower end): the bevel is cut from
    ///   `edgeZ + depth` down to `edgeZ`, the tip finishes at `edgeZ - h0`.
    /// - `.top` edge (contour = the edge on the top surface, at `edgeZ`, default 0): the bevel is
    ///   cut from `edgeZ` down to `edgeZ - depth`, the tip finishes at `edgeZ - depth - h0`.
    ///
    /// A shallower tip makes a smaller cone that sits inside the final one, so the stepdown passes
    /// never gouge: every pass removes a wedge and the last one leaves the finished bevel.
    /// `settings.cutting.stepdown` sets the pass depths, measured from the bevel's top.
    ///
    /// Throws `SC.Error.toolIncompatible` (not a V-bit with an angle), `SC.Error.invalidParameter`
    /// (negative tip offset, tip flat not smaller than the diameter),
    /// `SC.Error.chamferExceedsToolReach` (the bevel's depth plus `tipOffset` is taller than the
    /// tool's angled flank) and `SC.Error.invalidContour` (no usable geometry).
    func buildChamferToolpath(for contour: SC.Contour,
                              tool: SC.ToolParams,
                              settings: SC.MachineSettings,
                              params: SC.ChamferParams,
                              operation: SC.MachiningOperation) throws -> SC.OutputToolpath {

        try params.validateReach(for: tool)
        guard let bevel = params.resolvedBevel(for: tool), let vAngle = tool.vAngle else {
            throw SC.Error.toolIncompatible
        }

        let baseSegments = contour.linearizedSegments
        guard !baseSegments.isEmpty else {
            throw SC.Error.invalidContour
        }

        let tanHalf = tan((vAngle / 2.0).degreesToRadians)
        let range = params.bevelZRange(depth: bevel.depth)

        // The fixed tool-center offset: the final pass puts the tip on the contour, so only the
        // tip flat and the tip offset move the tool center away from it.
        let centerOffset = max(tool.tipWidth / 2 + params.tipOffset * tanHalf, 0)

        // Orient the chain so travel direction matches the requested climb/conventional cut,
        // same as `.contour`, then offset it once for all passes.
        let oriented = orientedForDirection(baseSegments, side: params.side, direction: params.direction)
        let toolpathSegments = offsetContour(oriented,
                                             side: params.side,
                                             toolRadius: centerOffset,
                                             isClosed: contour.isClosed)
        guard !toolpathSegments.isEmpty else {
            throw SC.Error.geometryCollapsed
        }

        // Bevel-bottom Z reached by each pass, from just below the bevel's top down to its bottom;
        // the tool tip is `tipOffset` below that.
        let bevelBottoms = EngineTools.calculateZPasses(targetDepth: bevel.depth,
                                                        stepdown: settings.cutting.stepdown).map { range.top + $0 }
        let passes = bevelBottoms.enumerated().map { index, bevelBottom in
            let tipZ = bevelBottom - params.tipOffset
            return SC.ToolpathPass(passIndex: index,
                                   depthZ: tipZ,
                                   waypoints: buildWaypoints(for: toolpathSegments, atZ: tipZ, settings: settings))
        }

        return SC.OutputToolpath(operation: operation, tool: tool, settings: settings, passes: passes)
    }
}
