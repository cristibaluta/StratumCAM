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
            guard let contour = restPocket(for: corner, smallRadius: smallRadius) else {
                skipped += 1
                continue
            }
            do {
                var built = try generateToolpaths(from: [contour], tool: tool, settings: rest, operation: operation)
                for i in built.indices {
                    built[i].name = "Rest corner \(index + 1)"
                    // The small tool's own corners aren't the ones to hand to another rest pass.
                    built[i].restCorners = []
                }
                outputs += built
            } catch SC.Error.geometryCollapsed {
                // The corner is too narrow for this tool.
                skipped += 1
            }
        }

        if skipped > 0, !outputs.isEmpty {
            outputs[0].warnings.append(.restCornersSkipped(count: skipped))
        }
        return outputs
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
