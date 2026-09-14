//
//  SCOffsetEngine.swift
//  StratumCAM
//

import Foundation
import CoreGraphics

// Calculate offsets

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

        let distance = OffsetTools.offsetDistance(for: side, toolRadius: toolRadius, segments: segments)

        // Offset every segment on its own first, keeping a `nil` in place (rather
        // than dropping it immediately) for any segment that can't offset by this
        // distance -- in practice almost always a corner-fillet arc whose radius
        // has run out before the rest of the shape has. `rawOffsets` stays the same
        // length/index alignment as `segments` so the filtering below can tell
        // exactly which original segment each collapse belongs to.
        let rawOffsets: [SC.Segment?] = segments.map { $0.offset(by: distance) }

        // Drop collapsed segments from both the offset list and its matching
        // original list together, so a corner that can no longer offset simply
        // vanishes from the chain -- its two former neighbors become directly
        // adjacent and `joinOffsetChain` below joins them into a sharp corner
        // (trimmed to their intersection, the same way it already handles any
        // other corner) instead of the whole offset bailing out just because one
        // local feature ran out of room. Only when *every* segment collapses
        // (guard below) does that mean the tool doesn't fit this shape at all.
        var filteredOriginal: [SC.Segment] = []
        var filteredOffset: [SC.Segment] = []
        filteredOriginal.reserveCapacity(segments.count)
        filteredOffset.reserveCapacity(segments.count)

        for (index, offsetSegment) in rawOffsets.enumerated() {
            guard let offsetSegment else {
                continue
            }
            filteredOriginal.append(segments[index])
            filteredOffset.append(offsetSegment)
        }

        guard !filteredOffset.isEmpty else {
            // Every segment collapsed -- the tool doesn't fit this shape at all,
            // not just one corner of it. Bail out to the un-offset path rather
            // than emit a broken (empty) toolpath.
            return segments
        }

        return joinOffsetChain(original: filteredOriginal, offset: filteredOffset, distance: distance, isClosed: isClosed)
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
                return GeoTools.lineLineIntersection(p1, p2, p3, p4)

            case let (.line(p1, p2), .arc(center, radius, _, _, _)):
                return GeoTools.circleLineIntersections(center: center, radius: radius, p1: p1, p2: p2)

            case let (.arc(center, radius, _, _, _), .line(p1, p2)):
                return GeoTools.circleLineIntersections(center: center, radius: radius, p1: p1, p2: p2)

            case let (.arc(c1, r1, _, _, _), .arc(c2, r2, _, _, _)):
                return GeoTools.circleCircleIntersections(c1: c1, r1: r1, c2: c2, r2: r2)
        }
    }
}
