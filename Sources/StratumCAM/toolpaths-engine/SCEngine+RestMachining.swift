//
//  SCEngine+RestMachining.swift
//  StratumCAM
//
//  A follow-up pass with a smaller tool over the pocket corners the larger tool couldn't
//  reach (see `restCorners(in:toolRadius:minDepth:)`).
//

import Foundation
import simd

extension SCEngine {

    /// Cuts the material a larger tool left in `corners` with the smaller `tool`.
    ///
    /// Per corner, a small pocket is built: the corner point, the two walls (extended a little
    /// past the larger tool's tangent points, never past the end of the wall) and a closing cap
    /// through area the larger tool already cleared. The existing offset pocket then clears it,
    /// at the same Z layers as `settings`. Only the two wall sides of that pocket are real
    /// walls; the others lie in air.
    ///
    /// `settings.allowance` and `finishingPass` are ignored (the rest pass cuts to size).
    ///
    /// - Returns: one toolpath per corner that was cut. Corners the smaller tool can't improve,
    ///   or that are too narrow for it, are left out and reported with a
    ///   `SC.Warning.restCornersSkipped` on the first toolpath. Empty when nothing was cut.
    /// - Throws: `SC.Error.toolIncompatible` when `tool` isn't smaller than the tool that left
    ///   the corners.
    public func generateRestToolpaths(corners: [SC.RestCorner],
                                      tool: SC.ToolParams,
                                      settings: SC.MachineSettings,
                                      direction: SC.CutDirection = .climb,
                                      entry: SC.EntryStrategy = .plunge) throws -> [SC.OutputToolpath] {

        guard let first = corners.first else {
            return []
        }
        let smallRadius = tool.diameter / 2.0
        guard smallRadius > 1e-9, tool.diameter < first.toolRadius * 2 - 1e-9 else {
            throw SC.Error.toolIncompatible
        }

        var rest = settings
        rest.allowance = 0
        rest.finishingPass = false

        let operation = SC.MachiningOperation.pocket(direction: direction, pattern: .offset, entry: entry)

        var outputs: [SC.OutputToolpath] = []
        var skipped = 0

        for (index, corner) in corners.enumerated() {
            guard let sweep = restSweep(for: corner, smallRadius: smallRadius, stepover: tool.diameter * settings.cutting.stepoverPercentage) else {
                skipped += 1
                continue
            }
            let zDepths = EngineTools.calculateZPasses(targetDepth: rest.targetDepth, stepdown: rest.cutting.stepdown)
            let passes = zDepths.enumerated().map { i, z in
                SC.ToolpathPass(passIndex: i, depthZ: z, waypoints: buildWaypoints(for: sweep, atZ: z, settings: rest))
            }
            outputs.append(SC.OutputToolpath(name: "Rest corner \(index + 1)",
                                             operation: operation,
                                             tool: tool,
                                             settings: rest,
                                             passes: passes))
        }

        if skipped > 0, !outputs.isEmpty {
            outputs[0].warnings.append(.restCornersSkipped(count: skipped))
        }
        return outputs
    }

    /// The tool-centre path that clears one corner: straight passes across the corner (between
    /// the two wall ends where the larger tool stopped), each one stepover closer to the sharp
    /// corner, alternating direction, until the last one reaches the corner itself.
    /// Nil when the smaller tool wouldn't improve on the larger one by a worthwhile amount.
    func restSweep(for corner: SC.RestCorner, smallRadius: Double, stepover: Double) -> [SC.Segment]? {

        let bigRadius = corner.toolRadius
        let halfAngle = corner.interiorAngle / 2
        guard halfAngle > 1e-6, halfAngle < Double.pi / 2 + 1e-9 else {
            return nil
        }
        let factor = 1 / sin(halfAngle) - 1
        guard bigRadius * factor - smallRadius * factor >= 0.01 else {
            return nil
        }

        let tin = corner.tangentIn
        let tout = corner.tangentOut
        let bx = tout.x - tin.x, by = tout.y - tin.y
        let bLength = hypot(bx, by)
        guard bLength > 1e-9 else {
            return nil
        }
        let bisector = CGPoint(x: bx / bLength, y: by / bLength)   // into the pocket
        let across = CGPoint(x: -bisector.y, y: bisector.x)

        // Distance along the bisector from the corner to the tool centre when the small tool
        // touches both walls: the innermost pass, a single point.
        let tNear = smallRadius / sin(halfAngle)
        // Outermost pass: where the tool centre is level with the wall ends (the larger tool's
        // tangent points, plus a margin, never past the end of a wall).
        let tangentDistance = bigRadius / tan(halfAngle)
        let along = min(tangentDistance + smallRadius, corner.incomingWallLength, corner.outgoingWallLength)
        let tFar = along * cos(halfAngle) + smallRadius * sin(halfAngle)
        guard tFar > tNear + 1e-6 else {
            return nil
        }

        // Evenly spaced levels no further apart than the stepover, ending exactly on the corner.
        let step = max(stepover, 1e-3)
        let count = max(1, Int(ceil((tFar - tNear) / step - 1e-9)))
        let c = corner.corner
        let tanHalf = tan(halfAngle)

        func point(t: Double, side: Double) -> CGPoint {
            let halfWidth = (t - tNear) * tanHalf
            return CGPoint(x: c.x + bisector.x * t + across.x * halfWidth * side,
                           y: c.y + bisector.y * t + across.y * halfWidth * side)
        }

        var segments: [SC.Segment] = []
        var side = -1.0
        var current = point(t: tFar, side: side)
        for i in 0...count {
            let t = tFar - (tFar - tNear) * Double(i) / Double(count)
            if i > 0 {
                // Step in along the wall to the next level, then cross.
                let along = point(t: t, side: side)
                segments.append(.line(start: current, end: along))
                current = along
            }
            let end = point(t: t, side: -side)
            if hypot(end.x - current.x, end.y - current.y) > 1e-9 {
                segments.append(.line(start: current, end: end))
                current = end
            }
            side = -side
        }
        return segments.isEmpty ? nil : segments
    }

    /// The small pocket that covers one corner's leftover, or nil when the smaller tool
    /// wouldn't improve on the larger one by a worthwhile amount.
    func restPocket(for corner: SC.RestCorner, smallRadius: Double) -> SC.Contour? {

        let bigRadius = corner.toolRadius
        let halfAngle = corner.interiorAngle / 2
        guard halfAngle > 1e-6, halfAngle < Double.pi / 2 + 1e-9 else {
            return nil
        }

        // How far the corner point is from the tool circle, for each tool.
        let factor = 1 / sin(halfAngle) - 1
        guard bigRadius * factor - smallRadius * factor >= 0.01 else {
            return nil
        }

        let tangentDistance = bigRadius / tan(halfAngle)
        let margin = max(2 * smallRadius, 0.5)
        let alongIn = min(tangentDistance + margin, corner.incomingWallLength)
        let alongOut = min(tangentDistance + margin, corner.outgoingWallLength)

        let c = corner.corner
        let tin = corner.tangentIn
        let tout = corner.tangentOut

        let p1 = CGPoint(x: c.x - tin.x * alongIn, y: c.y - tin.y * alongIn)
        let p2 = CGPoint(x: c.x + tout.x * alongOut, y: c.y + tout.y * alongOut)

        // Into the pocket, along the interior bisector, as far as the larger tool's centre.
        let bx = tout.x - tin.x, by = tout.y - tin.y
        let bLength = hypot(bx, by)
        guard bLength > 1e-9 else {
            return nil
        }
        let depth = bigRadius / sin(halfAngle)
        let shift = CGPoint(x: bx / bLength * depth, y: by / bLength * depth)
        let p2Far = CGPoint(x: p2.x + shift.x, y: p2.y + shift.y)
        let p1Far = CGPoint(x: p1.x + shift.x, y: p1.y + shift.y)

        let ring = [p1, c, p2, p2Far, p1Far]
        let entities = ring.indices.map { i -> SC.Contour.Chained in
            let a = ring[i]
            let b = ring[(i + 1) % ring.count]
            return SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(a.x, a.y), b: SIMD2<Double>(b.x, b.y)),
                                      reversed: false)
        }
        return SC.Contour(entities: entities, isClosed: true)
    }
}
