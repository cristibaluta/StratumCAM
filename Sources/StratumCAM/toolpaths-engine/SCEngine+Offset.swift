//
//  SCOffsetEngine.swift
//  StratumCAM
//

import Foundation
import CoreGraphics

// Calculate offsets

extension SCEngine {

    /// Offsets a linearized contour by the tool radius and returns the single longest
    /// resulting loop. `.onContour` (or a zero radius) is a no-op, and an offset that
    /// leaves nothing (the tool doesn't fit anywhere) returns the input unchanged -- the
    /// "tool too big" signal `pocketRings` relies on.
    ///
    /// When the shape splits into several loops (a neck narrower than the tool pinches it
    /// in two) only the largest loop comes back from this function; use `offsetContours`
    /// to get all of them.
    public func offsetContour(_ segments: [SC.Segment], side: SC.CutSide, toolRadius: Double, isClosed: Bool) -> [SC.Segment] {
        guard side != .onContour, toolRadius > 0, !segments.isEmpty else {
            return segments
        }
        return offsetContours(segments, side: side, toolRadius: toolRadius, isClosed: isClosed).first ?? segments
    }

    /// Offsets a linearized contour by the tool radius, producing every closed loop the
    /// tool centre can travel along for an inside or outside profile cut, largest first.
    ///
    /// - A closed contour is first offset with the exact segment-by-segment construction
    ///   below (`exactOffsetContour`), which keeps true arcs. That result is then checked:
    ///   it must not cross itself and no point of it may come closer to the original
    ///   contour than the tool radius, which is the actual "bit collision" test. If it
    ///   passes it is returned as the single loop.
    /// - If it fails (a neck or notch the tool can't follow, hairpin corners, a shape that
    ///   splits), the contour is offset again as a polygon (`PolygonOffset`): arcs are
    ///   flattened to short lines, the raw offset curve is split at every self-crossing,
    ///   and only the pieces bounding the region the tool can actually reach are kept.
    ///   That can return several loops, or none.
    /// - An empty array means the tool doesn't fit anywhere on this contour.
    /// - `.onContour`, a zero radius, and open chains return the exact construction as-is.
    public func offsetContours(_ segments: [SC.Segment], side: SC.CutSide, toolRadius: Double, isClosed: Bool) -> [[SC.Segment]] {
        // Trimming can collapse an arc to a point; drop those so no zero-length arc (which a
        // controller would read as a full circle) is ever turned into a waypoint.
        offsetContoursUncleaned(segments, side: side, toolRadius: toolRadius, isClosed: isClosed)
            .map { $0.removingDegenerate }
    }

    private func offsetContoursUncleaned(_ segments: [SC.Segment], side: SC.CutSide, toolRadius: Double, isClosed: Bool) -> [[SC.Segment]] {
        guard side != .onContour, toolRadius > 0, !segments.isEmpty else {
            return [segments]
        }

        var clock = OffsetTiming.now()
        let exact = exactOffsetContour(segments, side: side, toolRadius: toolRadius, isClosed: isClosed)
        let exactTime = OffsetTiming.lap(&clock)
        guard isClosed else {
            return [exact]
        }

        // Chord error for flattened arcs: fine enough to be invisible at the cutter, loose
        // enough to keep the point count reasonable.
        let tolerance = min(max(toolRadius * 0.001, 1e-4), 0.01)
        let original = PolygonOffset.flatten(segments, tolerance: tolerance)
        let flattenTime = OffsetTiming.lap(&clock)
        guard original.count >= 3 else {
            return [exact] // Degenerate input (a point or a single line): nothing to validate against.
        }

        OffsetTiming.log("offsetContours: \(segments.count) segments (\(original.count) pts flattened), tool radius \(toolRadius), tolerance \(tolerance) | exact offset \(exactTime) ms, flatten \(flattenTime) ms")

        if exact != segments {
            let candidate = PolygonOffset.flatten(exact, tolerance: tolerance)
            let valid = PolygonOffset.isValidOffset(candidate, of: original, radius: toolRadius, tolerance: tolerance)
            OffsetTiming.log("offsetContours: exact result \(valid ? "kept" : "rejected, falling back to polygon offset") (flatten + validate \(OffsetTiming.lap(&clock)) ms)")
            if valid {
                return [exact]
            }
        }

        let distance = OffsetTools.offsetDistance(for: side, toolRadius: toolRadius, segments: segments)
        let loops = PolygonOffset.offset(polygon: original, distance: distance, tolerance: tolerance)
        let result = loops
            .sorted { abs(PolygonOffset.signedArea($0)) > abs(PolygonOffset.signedArea($1)) }
            .map { PolygonOffset.segments(from: $0) }
        OffsetTiming.log("offsetContours: polygon offset -> \(result.count) loops, \(result.map { $0.count }) segments each (\(OffsetTiming.lap(&clock)) ms)")
        return result
    }

    /// The exact segment-by-segment offset: every segment is shifted on its own and
    /// neighbouring ones are joined at their corners, keeping true arcs.
    ///
    /// Known limitation: this only cleans up *local* self-intersections -- the gap
    /// between two adjacent offset segments at one corner (`joinOffsetChain` below,
    /// including its fallback to a tool-radius pivot arc when a sharp concave notch
    /// has no usable nearby trim point). It does not detect *global*
    /// self-intersections, where the offset curve loops back and crosses a segment
    /// further away in the same chain (e.g. a tool radius that's larger than a narrow
    /// neck/waist can support, so the offset boundaries from two different parts of
    /// the shape overlap each other). `offsetContours` above validates this function's
    /// result for closed contours and replaces it with a polygon offset when it's wrong.
    func exactOffsetContour(_ segments: [SC.Segment], side: SC.CutSide, toolRadius: Double, isClosed: Bool) -> [SC.Segment] {
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
        var bridges: [Int: SC.Segment] = [:]

        let count = working.count
        let pairCount = isClosed ? count : count - 1

        // A trimmed corner point should land within a sane multiple of the offset
        // distance from the original vertex. This bound exists to catch a specific
        // failure mode of `intersectionCandidates`: it treats lines as infinite and
        // arcs as full circles (see its doc comment), so the "intersection" it solves
        // for is really a miter join -- and a miter join's distance from the vertex is
        // distance / sin(halfTurnAngle). That's well-behaved for an ordinary corner,
        // but blows up for a sharp, near-reversing concave notch (a "hairpin": incoming
        // and outgoing tangents pointing almost directly back at each other, halfTurnAngle
        // near 0) -- exactly the kind of tight cusp you get at the pinched "neck" of a
        // figure-8/keyring shape. A 1-degree hairpin there already extrapolates the trim
        // point to ~57x the tool radius away from the true corner; sharper notches make
        // it worse, and worse in direct proportion regardless of how small the tool is,
        // since the multiplier (1/sin(halfTurnAngle)) only depends on the notch's own
        // angle, not on `distance`. Left unchecked, that distant point gets spliced
        // straight into the toolpath, producing the long spiking, self-crossing loops
        // seen at the neck. 25x the offset distance comfortably covers legitimate
        // trims while rejecting these blow-ups; the floor keeps the bound meaningful
        // when `distance` itself is tiny.
        let maxReasonableTrimDistance = max(abs(distance) * 25.0, 1.0)

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
                let candidates = intersectionCandidates(curr, next).filter {
                    hypot($0.x - vertex.x, $0.y - vertex.y) <= maxReasonableTrimDistance
                }
                if let closest = candidates.min(by: {
                    hypot($0.x - vertex.x, $0.y - vertex.y) < hypot($1.x - vertex.x, $1.y - vertex.y)
                }) {
                    working[i] = curr.withEnd(closest)
                    working[j] = next.withStart(closest)
                } else {
                    // No usable nearby intersection: either the segments are truly
                    // parallel, or (the sharp-notch case above) the only solution was
                    // an unreasonable miter-join extrapolation. Physically this means
                    // the tool is too wide to reach into this notch at all -- it can
                    // only pivot around the original vertex, the same way a convex
                    // corner gets a fillet. `gapStart`/`gapEnd` are each still exactly
                    // `distance` from `vertex` (offsetting a segment is a rigid
                    // shift/radius change, so its endpoint stays exactly that far from
                    // the corner it came from), so a tool-radius arc through both is
                    // an exact fit, not an approximation -- and it's what the tool's
                    // edge actually traces rolling across the gap, unlike a
                    // straight-line shortcut that cuts across the notch instead of
                    // following it.
                    let startAngle = atan2(gapStart.y - vertex.y, gapStart.x - vertex.x)
                    let endAngle = atan2(gapEnd.y - vertex.y, gapEnd.x - vertex.x)
                    // Sweep the short way around -- the tool rolls smoothly past the
                    // tip rather than looping the long way around the vertex.
                    var sweep = endAngle - startAngle
                    while sweep > .pi { sweep -= 2 * .pi }
                    while sweep < -.pi { sweep += 2 * .pi }
                    bridges[i] = .arc(center: vertex, radius: abs(distance), startAngle: startAngle, endAngle: endAngle, isCCW: sweep > 0)
                }
            }
        }

        var result: [SC.Segment] = []
        for i in 0..<count {
            result.append(working[i])
            if let fillet = fillets[i] {
                result.append(fillet)
            } else if let bridge = bridges[i] {
                result.append(bridge)
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
