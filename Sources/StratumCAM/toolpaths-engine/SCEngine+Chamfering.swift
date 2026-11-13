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
    /// pass to pass. The offset is the one at which the FINAL pass puts the flank exactly on the
    /// bevel (θ = half the V-bit angle, t = the tool's tip flat, h0 = `tipOffset`, z0 = Z of the
    /// selected contour, zTip = the final tip Z):
    ///
    ///     offset = t/2 + (z0 - zTip) * tan θ
    ///
    /// - `.bottom` edge (contour = the wall at the bevel's lower end): zTip = z0 - h0, so with a
    ///   sharp tip the tool center runs ON the contour; a tip flat moves it out by t/2 (the flat's
    ///   outer corner then touches the edge), a tip offset by h0 * tan θ more. The bevel is cut
    ///   from the top down and ends on the edge.
    /// - `.top` edge (contour = the bevel's upper edge): the tool runs one bevel width (plus the
    ///   same tip terms) away from the contour, toward the tool side.
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
        // Z of the selected contour: the bevel's top for a top edge, its bottom for a bottom edge.
        let contourZ = (params.edge == .top) ? range.top : range.bottom

        // The fixed tool-center offset, taken from the final pass (the tip `tipOffset` below the
        // bevel's bottom).
        let finalTipZ = range.bottom - params.tipOffset
        let centerOffset = max(tool.tipWidth / 2 + (contourZ - finalTipZ) * tanHalf, 0)

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
