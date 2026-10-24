//
//  SCEngine+PocketBoundary.swift
//  StratumCAM
//
//  Pockets drawn the way CAD users actually draw them:
//
//  1. An open outline whose two ends land on a wall (a semicircle pushed into a corner, a
//     slot-shaped notch cut into a wall...) is not a mistake, it is an island that shares
//     part of its outline with the wall. `closingOpenContours` closes it against the wall.
//  2. An island that touches or crosses the wall (a block standing on the wall, the closed
//     outline from 1.) cannot be handled as a keep-out zone floating inside the pocket,
//     because its zone would stick through the tool-centre wall ring. `mergingTouchingIslands`
//     subtracts it from the wall instead, so the pocket simply gets a notch in its boundary
//     and every clearing pattern sees an ordinary closed boundary.
//

import Foundation
import CoreGraphics

extension SCEngine {

    // MARK: - Open outlines closed by the wall

    /// Closes every open contour whose two ends both lie on the outline of a closed contour.
    ///
    /// The open outline and one of the two stretches of wall between its ends enclose a
    /// region. The closed contour that comes back is that region (the smaller of the two
    /// candidates -- the other one would be nearly the whole pocket), so it is an island that
    /// shares part of its boundary with the wall. Contours that don't meet any wall with
    /// both ends are returned untouched (and `buildPocketToolpath` still rejects them as
    /// `contourNotClosed`).
    func closingOpenContours(_ contours: [SC.Contour], tolerance: Double = 1e-3) -> [SC.Contour] {

        guard contours.contains(where: { !$0.isClosed }) else {
            return contours
        }

        struct Host {
            let segments: [SC.Segment]
            let area: Double
        }
        var hosts: [Host] = []
        for contour in contours where contour.isClosed {
            let segments = contour.linearizedSegments
            guard segments.count >= 2 || (segments.count == 1 && isArc(segments[0])) else {
                continue
            }
            hosts.append(Host(segments: segments, area: loopArea(segments)))
        }

        var result: [SC.Contour] = []
        for contour in contours {
            guard !contour.isClosed else {
                result.append(contour)
                continue
            }
            let open = contour.linearizedSegments
            guard let first = open.first, let last = open.last, isContiguous(open, tolerance: tolerance) else {
                result.append(contour)
                continue
            }
            let start = first.startPoint, end = last.endPoint

            // A chain that already comes back to its own start is simply closed.
            if hypot(start.x - end.x, start.y - end.y) <= tolerance {
                var closed = contour
                closed.isClosed = true
                result.append(closed)
                continue
            }

            // The smallest closed outline that has both ends on its wall.
            let host = hosts
                .filter { distance(from: start, toLoop: $0.segments) <= tolerance
                            && distance(from: end, toLoop: $0.segments) <= tolerance }
                .min { $0.area < $1.area }

            guard let host, let paths = zonePaths(host.segments, from: end, to: start, tolerance: tolerance) else {
                result.append(contour)
                continue
            }

            // Candidates: the open outline followed by either way round the wall back to its start.
            let candidates = [open + paths.forward, open + paths.backward]
            guard let island = candidates.min(by: { loopArea($0) < loopArea($1) }), loopArea(island) > 1e-9 else {
                result.append(contour)
                continue
            }
            result.append(self.contour(from: island))
        }
        return result
    }

    // MARK: - Islands merged into the wall

    /// Subtracts every island that touches or crosses its pocket's wall from the wall itself.
    /// The pocket's boundary gets a notch where the island stood; the island stops being an
    /// island. Islands that stay clear of the wall are left alone. A pocket that the islands
    /// cut into several pieces comes back as several pockets.
    func mergingTouchingIslands(_ contours: [SC.Contour]) -> [SC.Contour] {

        var result: [SC.Contour] = []

        for pocket in contours {
            guard pocket.isClosed, !pocket.islands.isEmpty else {
                result.append(pocket)
                continue
            }
            let wall = pocket.linearizedSegments
            guard !wall.isEmpty else {
                result.append(pocket)
                continue
            }

            var loops: [[SC.Segment]] = [counterClockwise(wall)]
            var free: [SC.Contour] = []
            var didMerge = false

            for island in pocket.islands {
                let outline = counterClockwise(island.linearizedSegments)
                guard island.isClosed, !outline.isEmpty else {
                    free.append(island)
                    continue
                }

                // Which of the current loops does the island interact with?
                guard let index = loops.firstIndex(where: { loopsInteract($0, outline) }) else {
                    free.append(island)
                    continue
                }
                guard let pieces = subtract(outline, from: loops[index]) else {
                    free.append(island) // couldn't be merged: the zone validation will report it
                    continue
                }
                didMerge = true
                loops.remove(at: index)
                loops.append(contentsOf: pieces.filter { OffsetTools.isCCWWinding($0) })
                // A clockwise leftover is a hole the island left in the pocket.
                free.append(contentsOf: pieces.filter { !OffsetTools.isCCWWinding($0) }.map { self.contour(from: $0) })
            }

            guard didMerge else {
                result.append(pocket)
                continue
            }

            for loop in loops {
                var merged = self.contour(from: loop)
                merged.islands = free.filter { island in
                    guard let sample = island.linearizedSegments.first?.startPoint else {
                        return false
                    }
                    return isInsideLoop(sample, loop: loop)
                }
                result.append(merged)
            }
        }
        return result
    }

    // MARK: - Loop boolean: outer minus island

    /// `outer` with `island` cut out of it, as closed loops (counter-clockwise ones are pocket
    /// outlines, clockwise ones holes). Both loops must be counter-clockwise. `nil` when the
    /// pieces can't be put back together into closed loops.
    ///
    /// Both outlines are split wherever they cross or touch each other, then every piece is
    /// kept or dropped by looking at what lies just beside it:
    ///  - a piece of `outer` stays when the side facing the pocket's interior is not inside the
    ///    island;
    ///  - a piece of `island` stays (reversed, so it still has the pocket on its left) when the
    ///    side facing away from the island is inside `outer`.
    /// Pieces where the two outlines run on top of each other drop out of both tests.
    func subtract(_ island: [SC.Segment], from outer: [SC.Segment]) -> [[SC.Segment]]? {

        let tolerance = 1e-5

        func splitAll(_ loop: [SC.Segment], against other: [SC.Segment]) -> [SC.Segment] {
            var pieces: [SC.Segment] = []
            for segment in loop {
                var parameters = other.flatMap { intersectionParameters(of: segment, with: $0) }
                // Vertices of the other outline that sit on this segment (needed where the two
                // outlines overlap, which has no proper crossing).
                for otherSegment in other {
                    for point in [otherSegment.startPoint, otherSegment.endPoint] {
                        if let found = parameter(of: point, on: segment, tolerance: tolerance) {
                            parameters.append(found)
                        }
                    }
                }
                pieces.append(contentsOf: split(segment, atParameters: parameters))
            }
            return pieces.filter { !$0.isDegenerate }
        }

        let outerPieces = splitAll(outer, against: island)
        let islandPieces = splitAll(island, against: outer)

        let probe = 1e-4
        var kept: [SC.Segment] = []

        for piece in outerPieces {
            guard let frame = midFrame(of: piece) else {
                continue
            }
            let left = CGPoint(x: frame.point.x - frame.tangent.y * probe, y: frame.point.y + frame.tangent.x * probe)
            if !isInsideLoop(left, loop: island) {
                kept.append(piece)
            }
        }
        for piece in islandPieces {
            guard let frame = midFrame(of: piece) else {
                continue
            }
            let right = CGPoint(x: frame.point.x + frame.tangent.y * probe, y: frame.point.y - frame.tangent.x * probe)
            if isInsideLoop(right, loop: outer) {
                kept.append(piece.reversed)
            }
        }

        guard !kept.isEmpty else {
            return []
        }

        // Chain the pieces end to start.
        var pool = kept
        var loops: [[SC.Segment]] = []
        let joinTolerance = 1e-4
        while !pool.isEmpty {
            var loop = [pool.removeFirst()]
            let origin = loop[0].startPoint
            while true {
                let end = loop[loop.count - 1].endPoint
                if hypot(end.x - origin.x, end.y - origin.y) < joinTolerance {
                    break
                }
                let candidates = pool.indices.filter {
                    hypot(pool[$0].startPoint.x - end.x, pool[$0].startPoint.y - end.y) < joinTolerance
                }
                guard !candidates.isEmpty else {
                    return nil
                }
                // Where several pieces leave the same point (outlines touching at a vertex),
                // take the one that turns most to the left, which keeps the loops simple.
                let incoming = direction(of: loop[loop.count - 1], atEnd: true)
                let best = candidates.max { a, b in
                    turn(from: incoming, to: direction(of: pool[a], atEnd: false))
                        < turn(from: incoming, to: direction(of: pool[b], atEnd: false))
                }!
                loop.append(pool.remove(at: best))
            }
            loops.append(loop)
        }
        return loops
    }

    /// Signed turn from direction `a` to direction `b` (positive = left), as an angle.
    private func turn(from a: CGPoint, to b: CGPoint) -> Double {
        atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y)
    }

    // MARK: - Helpers

    /// True when the two closed outlines cross, touch, or one has a point on the other.
    private func loopsInteract(_ a: [SC.Segment], _ b: [SC.Segment]) -> Bool {
        let tolerance = 1e-6
        for segment in b {
            for other in a where !intersectionParameters(of: segment, with: other).isEmpty {
                return true
            }
            for point in [segment.startPoint, midpoint(of: segment), segment.endPoint] {
                if distance(from: point, toLoop: a) < tolerance {
                    return true
                }
            }
        }
        // An island lying partly across the wall can have all its sample points off the wall
        // while still crossing it: look at the other direction as well.
        for segment in a {
            for point in [segment.startPoint, midpoint(of: segment)] where isInsideLoop(point, loop: b) {
                return true
            }
        }
        return false
    }

    private func isArc(_ segment: SC.Segment) -> Bool {
        if case .arc = segment { return true }
        return false
    }

    /// Whether each segment starts where the previous one ended.
    private func isContiguous(_ segments: [SC.Segment], tolerance: Double) -> Bool {
        for i in 1..<max(segments.count, 1) {
            let a = segments[i - 1].endPoint, b = segments[i].startPoint
            if hypot(a.x - b.x, a.y - b.y) > tolerance {
                return false
            }
        }
        return true
    }

    /// Unsigned area enclosed by a closed loop of segments.
    func loopArea(_ loop: [SC.Segment]) -> Double {
        abs(PolygonOffset.signedArea(PolygonOffset.flatten(loop, tolerance: 1e-3)))
    }

    /// `loop` travelling counter-clockwise.
    func counterClockwise(_ loop: [SC.Segment]) -> [SC.Segment] {
        guard !loop.isEmpty, !OffsetTools.isCCWWinding(loop) else {
            return loop
        }
        return loop.reversed().map { $0.reversed }
    }

    /// The middle of `segment` and the unit tangent there.
    func midFrame(of segment: SC.Segment) -> (point: CGPoint, tangent: CGPoint)? {
        switch segment {
            case .line(let a, let b):
                let length = hypot(b.x - a.x, b.y - a.y)
                guard length > 1e-12 else {
                    return nil
                }
                return (CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2),
                        CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length))

            case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                let sweep = SC.Segment.sweepAngle(start: startAngle, end: endAngle, isCCW: isCCW)
                guard sweep > 1e-12 else {
                    return nil
                }
                let angle = startAngle + (isCCW ? 1.0 : -1.0) * sweep / 2
                let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                let tangent = isCCW ? CGPoint(x: -sin(angle), y: cos(angle)) : CGPoint(x: sin(angle), y: -cos(angle))
                return (point, tangent)
        }
    }

    /// An `SC.Contour` that traces `segments` (a closed loop), as one closed polyline whose
    /// arcs are carried by bulges.
    func contour(from segments: [SC.Segment]) -> SC.Contour {
        var vertices: [SC.Geometry.Vertex] = []
        for segment in segments {
            let start = segment.startPoint
            var bulge = 0.0
            if case .arc(_, _, let startAngle, let endAngle, let isCCW) = segment {
                let sweep = SC.Segment.sweepAngle(start: startAngle, end: endAngle, isCCW: isCCW)
                bulge = tan(sweep / 4) * (isCCW ? 1.0 : -1.0)
            }
            vertices.append(SC.Geometry.Vertex(SIMD2<Double>(start.x, start.y), bulge: bulge))
        }
        return SC.Contour(entities: [SC.Contour.Chained(geometry: .polyline(vertices: vertices, closed: true), reversed: false)],
                          isClosed: true)
    }
}
