//
//  SCEngine+RestCorners.swift
//  StratumCAM
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// Finds the sharp pocket corners a round tool of `toolRadius` cannot reach, so a
    /// caller can run a follow-up (rest machining) pass with a smaller tool.
    ///
    /// Only line-line vertices are handled for now. A vertex leaves material when the
    /// pocket interior angle there is below 180 degrees. The leftover region is bounded by
    /// the two wall lines up to the tangent points and the tool-circle arc between them.
    ///
    /// - Parameters:
    ///   - minDepth: corners where the tool leaves less than this (mm, measured from the corner
    ///     point to the tool circle) are ignored. Keeps a polygon-approximated circle from
    ///     reporting a corner at every vertex.
    ///
    /// Known limits: line-to-arc corners, concave arcs tighter than the tool, and islands
    /// (only the given outer boundary is looked at) are not handled.
    ///
    /// A wall shorter than the tangent distance keeps its corner: the tangent points are
    /// clamped to the wall ends and the region is closed with a straight chord instead of
    /// the tool arc (a slightly larger region, never a smaller one).
    func restCorners(in boundary: [SC.Segment], toolRadius: Double, minDepth: Double = 0.03) -> [SC.RestCorner] {

        guard boundary.count >= 3, toolRadius > 1e-9 else {
            return []
        }

        let isCCW = OffsetTools.isCCWWinding(boundary)
        var result: [SC.RestCorner] = []

        for i in 0..<boundary.count {
            let incoming = boundary[i]
            let outgoing = boundary[(i + 1) % boundary.count]

            guard case .line(let a, let c) = incoming, case .line(_, let b) = outgoing else {
                continue
            }

            let inLen = hypot(c.x - a.x, c.y - a.y)
            let outLen = hypot(b.x - c.x, b.y - c.y)
            guard inLen > 1e-9, outLen > 1e-9 else {
                continue
            }

            let tin = CGPoint(x: (c.x - a.x) / inLen, y: (c.y - a.y) / inLen)
            let tout = CGPoint(x: (b.x - c.x) / outLen, y: (b.y - c.y) / outLen)

            let cross = tin.x * tout.y - tin.y * tout.x
            let dot = tin.x * tout.x + tin.y * tout.y

            // Convex vertex of the pocket (interior angle < 180): left turn for CCW, right for CW.
            let turn = isCCW ? cross : -cross
            guard turn > 1e-9 else {
                continue
            }

            // Exterior turning angle is atan2(|cross|, dot); interior angle = pi - that.
            let interior = Double.pi - atan2(abs(cross), dot)
            let halfAngle = interior / 2
            let tangentDistance = toolRadius / tan(halfAngle)

            // A wall shorter than the tangent distance: clamp the tangent points to its end.
            let isClamped = tangentDistance > inLen + 1e-9 || tangentDistance > outLen + 1e-9
            let in1 = min(tangentDistance, inLen)
            let out1 = min(tangentDistance, outLen)

            let t1 = CGPoint(x: c.x - tin.x * in1, y: c.y - tin.y * in1)
            let t2 = CGPoint(x: c.x + tout.x * out1, y: c.y + tout.y * out1)

            // Tool center: along the interior bisector, at toolRadius from both walls.
            let bx = tout.x - tin.x, by = tout.y - tin.y
            let bLen = hypot(bx, by)
            guard bLen > 1e-9 else {
                continue
            }
            let centerDistance = toolRadius / sin(halfAngle)
            let o = CGPoint(x: c.x + bx / bLen * centerDistance, y: c.y + by / bLen * centerDistance)

            // Too shallow to be worth a pass.
            guard centerDistance - toolRadius >= minDepth else {
                continue
            }
            // The tool centre has to be inside the pocket, otherwise the tool doesn't fit here.
            guard Self.isPoint(o, insidePolygonOf: boundary) else {
                continue
            }

            let angle1 = atan2(t1.y - o.y, t1.x - o.x)
            let angle2 = atan2(t2.y - o.y, t2.x - o.x)
            // The leftover arc is the short way (< 180 degrees) from t2 back to t1.
            let v2 = CGPoint(x: t2.x - o.x, y: t2.y - o.y)
            let v1 = CGPoint(x: t1.x - o.x, y: t1.y - o.y)
            let arcIsCCW = (v2.x * v1.y - v2.y * v1.x) > 0

            let closing: SC.Segment = isClamped
                ? .line(start: t2, end: t1)
                : .arc(center: o, radius: toolRadius, startAngle: angle2, endAngle: angle1, isCCW: arcIsCCW)
            let region: [SC.Segment] = [
                .line(start: t1, end: c),
                .line(start: c, end: t2),
                closing
            ]

            result.append(SC.RestCorner(corner: c,
                                        tangentIn: tin,
                                        tangentOut: tout,
                                        interiorAngle: interior,
                                        toolRadius: toolRadius,
                                        region: region,
                                        incomingWallLength: inLen,
                                        outgoingWallLength: outLen))
        }

        return result
    }

    /// Even-odd test against the boundary's segment start points (the boundary is linearised).
    private static func isPoint(_ p: CGPoint, insidePolygonOf boundary: [SC.Segment]) -> Bool {
        let pts = boundary.map { $0.startPoint }
        var inside = false
        var j = pts.count - 1
        for i in 0..<pts.count {
            let a = pts[i], b = pts[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
