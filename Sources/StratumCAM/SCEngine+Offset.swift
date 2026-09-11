//
//  SCOffsetEngine.swift
//  StratumCAM
//
//  Tool-radius compensation: offsets a chain of segments by the tool
//  radius so `.inside` / `.outside` profile cuts leave the part at its
//  true drawn size instead of following the contour at cutter-center.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// Offsets a linearized contour by the tool radius, producing the true toolpath
    /// for an inside or outside profile cut. `.onContour` (or a zero radius) is a no-op.
    ///
    /// Known limitation: if the tool radius is bigger than the offset can support
    /// (self-intersecting loops in tight inside corners / small features), this does
    /// not clean up the resulting loops -- it returns the raw offset path as-is.
    public func offsetContour(_ segments: [SC.Segment], side: SC.CutSide, toolRadius: Double, isClosed: Bool) -> [SC.Segment] {
        guard side != .onContour, toolRadius > 0, !segments.isEmpty else {
            return segments
        }

        let distance = offsetDistance(for: side, toolRadius: toolRadius, segments: segments)
        let offsetSegments = segments.compactMap { $0.offset(by: distance) }

        guard offsetSegments.count == segments.count else {
            // A segment collapsed (tool too big for a feature) -- bail out to the
            // un-offset path rather than emit a broken toolpath.
            return segments
        }

        return joinOffsetChain(original: segments, offset: offsetSegments, distance: distance, isClosed: isClosed)
    }

    /// Resolves `.inside` / `.outside` into a signed offset distance (positive = left of
    /// travel direction), based on the contour's winding direction.
    func offsetDistance(for side: SC.CutSide, toolRadius: Double, segments: [SC.Segment]) -> Double {
        switch side {
        case .onContour:
            return 0
        case .outside:
            return isCCWWinding(segments) ? -toolRadius : toolRadius
        case .inside:
            return isCCWWinding(segments) ? toolRadius : -toolRadius
        }
    }

    // MARK: - Winding

    /// Approximates the signed area of a closed contour (sampling arcs) to determine
    /// winding direction. Positive area = counter-clockwise.
    func isCCWWinding(_ segments: [SC.Segment]) -> Bool {
        var points: [CGPoint] = []
        for segment in segments {
            switch segment {
                case .line(let start, _):
                    points.append(start)

                case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                    let sweep = isCCW ? (endAngle - startAngle) : (startAngle - endAngle)
                    let steps = max(1, Int(abs(sweep) / (.pi / 18))) // ~10 deg per sample
                    for s in 0..<steps {
                        let t = Double(s) / Double(steps)
                        let angle = startAngle + (isCCW ? sweep : -sweep) * t
                        points.append(
                            CGPoint(x: center.x + radius * cos(angle),
                                    y: center.y + radius * sin(angle))
                        )
                    }
            }
        }
        guard points.count >= 3 else {
            return true
        }

        var area = 0.0
        for i in 0..<points.count {
            let p1 = points[i]
            let p2 = points[(i + 1) % points.count]
            area += p1.x * p2.y - p2.x * p1.y
        }
        return area > 0
    }

    // MARK: - Corner joining

    /// Bridges the gaps between consecutively-offset segments: fillets convex corners
    /// with an arc of the tool radius, and trims concave corners back to their true
    /// intersection point.
    private func joinOffsetChain(original: [SC.Segment], offset: [SC.Segment], distance: Double, isClosed: Bool) -> [SC.Segment] {

        guard offset.count > 1 else {
            return offset
        }

        var working = offset
        var fillets: [Int: SC.Segment] = [:]

        let count = working.count
        let pairCount = isClosed ? count : count - 1

        for i in 0..<pairCount {
            let j = (i + 1) % count
            let curr = working[i]
            let next = working[j]

            let gapStart = curr.endPoint
            let gapEnd = next.startPoint
            guard hypot(gapEnd.x - gapStart.x, gapEnd.y - gapStart.y) > 1e-6 else {
                continue
            }

            let vertex = original[i].endPoint
            let inDir = direction(of: original[i], atEnd: true)
            let outDir = direction(of: original[j], atEnd: false)
            let turn = inDir.x * outDir.y - inDir.y * outDir.x // 2D cross product

            // A corner needs a fillet exactly when the turn direction and the offset
            // direction disagree -- that's what pulls the offset endpoints apart.
            // When they agree, the offset curves overlap and need trimming instead.
            let needsFillet = turn * distance < -1e-9

            if needsFillet {
                let startAngle = atan2(gapStart.y - vertex.y, gapStart.x - vertex.x)
                let endAngle = atan2(gapEnd.y - vertex.y, gapEnd.x - vertex.x)
                fillets[i] = .arc(center: vertex, radius: abs(distance), startAngle: startAngle, endAngle: endAngle, isCCW: turn > 0)
            } else {
                let candidates = intersectionCandidates(curr, next)
                if let closest = candidates.min(by: {
                    hypot($0.x - vertex.x, $0.y - vertex.y) < hypot($1.x - vertex.x, $1.y - vertex.y)
                }) {
                    working[i] = curr.withEnd(closest)
                    working[j] = next.withStart(closest)
                }
                // If no intersection exists (degenerate/parallel), we leave the small
                // gap as-is; the next waypoint move will implicitly bridge it. TODO:
                // insert an explicit bridging line for full robustness here.
            }
        }

        var result: [SC.Segment] = []
        for i in 0..<count {
            result.append(working[i])
            if let fillet = fillets[i] {
                result.append(fillet)
            }
        }
        return result
    }

    /// Unit tangent direction of travel at the start or end of a segment.
    func direction(of segment: SC.Segment, atEnd: Bool) -> CGPoint {
        switch segment {
            case .line(let start, let end):
                let dx = end.x - start.x, dy = end.y - start.y
                let len = hypot(dx, dy)
                guard len > 1e-9 else {
                    return CGPoint(x: 0, y: 0)
                }

                return CGPoint(x: dx / len, y: dy / len)

            case .arc(_, _, let startAngle, let endAngle, let isCCW):
                let angle = atEnd ? endAngle : startAngle
                let radialX = cos(angle), radialY = sin(angle)
                // Tangent is the radial vector rotated +-90 deg depending on sweep direction.
                return isCCW ? CGPoint(x: -radialY, y: radialX) : CGPoint(x: radialY, y: -radialX)
        }
    }

    // MARK: - Intersections

    /// Candidate intersection points between two segments, treating lines as infinite
    /// and arcs as full circles (since we only need the point nearest the original vertex).
    private func intersectionCandidates(_ a: SC.Segment, _ b: SC.Segment) -> [CGPoint] {
        switch (a, b) {
            case let (.line(p1, p2), .line(p3, p4)):
                return lineLineIntersection(p1, p2, p3, p4)
            case let (.line(p1, p2), .arc(center, radius, _, _, _)):
                return circleLineIntersections(center: center, radius: radius, p1: p1, p2: p2)
            case let (.arc(center, radius, _, _, _), .line(p1, p2)):
                return circleLineIntersections(center: center, radius: radius, p1: p1, p2: p2)
            case let (.arc(c1, r1, _, _, _), .arc(c2, r2, _, _, _)):
                return circleCircleIntersections(c1: c1, r1: r1, c2: c2, r2: r2)
        }
    }

    private func lineLineIntersection(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> [CGPoint] {
        let d1x = p2.x - p1.x, d1y = p2.y - p1.y
        let d2x = p4.x - p3.x, d2y = p4.y - p3.y
        let denom = d1x * d2y - d1y * d2x
        guard abs(denom) > 1e-9 else {
            return [] // parallel
        }
        let t = ((p3.x - p1.x) * d2y - (p3.y - p1.y) * d2x) / denom

        return [CGPoint(x: p1.x + t * d1x, y: p1.y + t * d1y)]
    }

    private func circleLineIntersections(center: CGPoint, radius: Double, p1: CGPoint, p2: CGPoint) -> [CGPoint] {
        let dx = p2.x - p1.x, dy = p2.y - p1.y
        let fx = p1.x - center.x, fy = p1.y - center.y
        let a = dx * dx + dy * dy
        guard a > 1e-12 else {
            return []
        }
        let b = 2 * (fx * dx + fy * dy)
        let c = fx * fx + fy * fy - radius * radius
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else {
            return []
        }
        let sq = discriminant.squareRoot()
        let t1 = (-b - sq) / (2 * a)
        let t2 = (-b + sq) / (2 * a)
        
        return [
            CGPoint(x: p1.x + t1 * dx, y: p1.y + t1 * dy),
            CGPoint(x: p1.x + t2 * dx, y: p1.y + t2 * dy)
        ]
    }

    private func circleCircleIntersections(c1: CGPoint, r1: Double, c2: CGPoint, r2: Double) -> [CGPoint] {
        let dx = c2.x - c1.x, dy = c2.y - c1.y
        let d = hypot(dx, dy)
        guard d > 1e-9, d <= r1 + r2 + 1e-6, d >= abs(r1 - r2) - 1e-6 else {
            return []
        }
        let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
        let h = max(0, r1 * r1 - a * a).squareRoot()
        let xm = c1.x + a * dx / d
        let ym = c1.y + a * dy / d

        return [
            CGPoint(x: xm + h * dy / d, y: ym - h * dx / d),
            CGPoint(x: xm - h * dy / d, y: ym + h * dx / d)
        ]
    }
}
