//
//  PolygonOffset.swift
//  StratumCAM
//

import Foundation
import CoreGraphics

/// Robust offsetting for closed contours, used when the exact segment-by-segment offset in
/// `SCEngine.offsetContour` can't be trusted (narrow necks, hairpin notches, tools wider
/// than a feature, shapes that split in two).
///
/// It follows the same recipe as Clipper's `InflatePaths`:
///
/// 1. Flatten arcs to a polyline (chord error <= `tolerance`).
/// 2. Build the *raw* offset curve: every edge shifted sideways, round joins on the outer
///    side of each corner, concave corners trimmed where the shifted edges really cross.
///    The raw curve is allowed to cross itself.
/// 3. Split the raw curve at every self-intersection.
/// 4. Keep a piece only if it bounds the region with winding number > 0 (the "union with
///    positive fill" step). Inverted loops and the parts of the curve that run through the
///    tool's own swept area have winding <= 0 and disappear.
/// 5. Chain the kept pieces into closed loops. A neck that pinches off simply yields
///    several loops; a tool that doesn't fit anywhere yields none.
///
/// All of this works in the polygon's own units; `tolerance` is the largest chord error
/// allowed when flattening arcs and approximating round joins.
enum PolygonOffset {

    // MARK: - Public entry points

    /// Offsets a closed polygon sideways by `distance` (positive = left of travel direction,
    /// like `SC.Segment.offset(by:)`).
    ///
    /// Returns closed loops (first point not repeated at the end), each keeping the travel
    /// direction of the input polygon. The array is empty when nothing is left, i.e. the
    /// tool doesn't fit anywhere.
    static func offset(polygon input: [CGPoint], distance: Double, tolerance: Double) -> [[CGPoint]] {

        let polygon = dedupe(input, epsilon: max(tolerance * 0.5, 1e-6))
        guard polygon.count >= 3 else {
            return []
        }
        guard abs(distance) > 1e-12 else {
            return [polygon]
        }

        let radius = abs(distance)

        // Work on a counter-clockwise polygon so "winding number > 0" always means "inside the
        // result". A clockwise input is reversed, which swaps left and right.
        let isClockwise = signedArea(polygon) < 0
        let oriented = isClockwise ? Array(polygon.reversed()) : polygon
        let leftDistance = isClockwise ? -distance : distance

        let raw = rawOffset(oriented, distance: leftDistance, tolerance: tolerance)
        guard raw.count >= 3 else {
            return []
        }

        let probe = max(tolerance * 0.1, 1e-7)
        var loops: [[CGPoint]] = []

        let split = splitAtSelfIntersections(raw)
        if !split.hadIntersections {
            // The raw curve is already simple: it's either the answer or fully inverted.
            switch classify(raw + [raw[0]], against: raw, probe: probe) {
                case 1:
                    loops = [raw]
                case -1:
                    loops = [Array(raw.reversed())]
                default:
                    loops = []
            }
        } else {
            var kept: [[CGPoint]] = []
            for piece in split.pieces {
                switch classify(piece, against: raw, probe: probe) {
                    case 1:
                        kept.append(piece)
                    case -1:
                        kept.append(Array(piece.reversed()))
                    default:
                        break
                }
            }
            loops = chain(kept)
        }

        // Drop hairline slivers (loops thinner than the tolerance), which come from tools that
        // fit with a hair to spare and would only produce a back-and-forth cut.
        loops = loops.filter { abs(signedArea($0)) >= tolerance * radius }

        if isClockwise {
            loops = loops.map { Array($0.reversed()) }
        }
        return loops
    }

    /// Flattens a chain of segments into the polygon of their start points plus arc samples.
    /// The chain is treated as closed: the last point connects back to the first.
    static func flatten(_ segments: [SC.Segment], tolerance: Double) -> [CGPoint] {

        var points: [CGPoint] = []
        for segment in segments {
            switch segment {
                case .line(let start, _):
                    points.append(start)

                case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                    var sweep = isCCW ? endAngle - startAngle : startAngle - endAngle
                    while sweep < 0 {
                        sweep += 2 * .pi
                    }
                    let steps = arcStepCount(radius: radius, sweep: sweep, tolerance: tolerance)
                    let signedSweep = isCCW ? sweep : -sweep
                    for k in 0..<steps {
                        let angle = startAngle + signedSweep * Double(k) / Double(steps)
                        points.append(pointOnCircle(center: center, radius: radius, angle: angle))
                    }
            }
        }
        return dedupe(points, epsilon: max(tolerance * 0.5, 1e-6))
    }

    /// Turns a closed loop into line segments, including the closing edge.
    static func segments(from loop: [CGPoint]) -> [SC.Segment] {
        guard loop.count >= 2 else {
            return []
        }
        var result: [SC.Segment] = []
        result.reserveCapacity(loop.count)
        for i in 0..<loop.count {
            result.append(.line(start: loop[i], end: loop[(i + 1) % loop.count]))
        }
        return result
    }

    /// Checks an offset produced by another algorithm (the exact-arc one in `offsetContour`):
    /// it must not cross itself, must run the same way round as the input, and no sampled
    /// point may be closer to the original polygon than the tool radius -- the actual
    /// definition of "the bit doesn't gouge anything".
    static func isValidOffset(_ candidate: [CGPoint],
                              of polygon: [CGPoint],
                              radius: Double,
                              tolerance: Double) -> Bool {

        guard candidate.count >= 3, polygon.count >= 3, radius > 0 else {
            return false
        }
        guard (signedArea(candidate) > 0) == (signedArea(polygon) > 0) else {
            return false
        }
        guard !hasSelfCrossing(candidate) else {
            return false
        }

        // A little slack: the candidate's arcs are flattened too, and the original polygon's
        // arcs are chords, so distances are only exact to about `tolerance`.
        let slack = max(radius * 0.01, tolerance * 4)
        let limit = radius - slack

        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for p in polygon {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let diagonal = hypot(maxX - minX, maxY - minY)
        let grid = SegmentGrid(polygon: polygon, cellSize: max(radius, diagonal / 512))

        let spacing = max(radius * 0.5, tolerance)
        let n = candidate.count
        for i in 0..<n {
            let a = candidate[i]
            let b = candidate[(i + 1) % n]
            let length = hypot(b.x - a.x, b.y - a.y)
            let steps = min(max(Int((length / spacing).rounded(.up)), 1), 2000)
            for k in 0..<steps {
                let t = Double(k) / Double(steps)
                let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                if grid.hasSegment(closerThan: limit, to: p) {
                    return false
                }
            }
        }
        return true
    }

    // MARK: - Geometry helpers

    static func signedArea(_ points: [CGPoint]) -> Double {
        var area = 0.0
        let n = points.count
        for i in 0..<n {
            let p1 = points[i]
            let p2 = points[(i + 1) % n]
            area += p1.x * p2.y - p2.x * p1.y
        }
        return area / 2
    }

    /// Removes consecutive points closer than `epsilon`, including across the closing edge.
    static func dedupe(_ points: [CGPoint], epsilon: Double) -> [CGPoint] {
        var result: [CGPoint] = []
        result.reserveCapacity(points.count)
        for p in points {
            if let last = result.last, hypot(p.x - last.x, p.y - last.y) <= epsilon {
                continue
            }
            result.append(p)
        }
        while result.count > 1,
              let first = result.first,
              let last = result.last,
              hypot(first.x - last.x, first.y - last.y) <= epsilon {
            result.removeLast()
        }
        return result
    }

    /// Everything in plain Double, so `cos`/`sin` don't have to pick between the Double and
    /// CGFloat overloads (which the compiler reports as "ambiguous use").
    private static func pointOnCircle(center: CGPoint, radius: Double, angle: Double) -> CGPoint {
        let x: Double = Double(center.x) + radius * cos(angle)
        let y: Double = Double(center.y) + radius * sin(angle)
        return CGPoint(x: x, y: y)
    }

    private static func arcStepCount(radius: Double, sweep: Double, tolerance: Double) -> Int {
        guard radius > tolerance else {
            return max(1, Int((sweep / (.pi / 2)).rounded(.up)))
        }
        let step = max(2 * acos(max(-1.0, min(1.0, 1 - tolerance / radius))), 1e-3)
        return max(1, Int((abs(sweep) / step).rounded(.up)))
    }

    /// Intersection of segments p1p2 and p3p4 with their parameters, or nil when they miss
    /// each other or are parallel. `tolerance` widens the accepted parameter range slightly so
    /// intersections at shared end points aren't lost to rounding.
    private static func segmentIntersection(_ p1: CGPoint, _ p2: CGPoint,
                                            _ p3: CGPoint, _ p4: CGPoint,
                                            tolerance: Double) -> (t: Double, u: Double, point: CGPoint)? {
        let d1x = p2.x - p1.x, d1y = p2.y - p1.y
        let d2x = p4.x - p3.x, d2y = p4.y - p3.y
        let denominator = d1x * d2y - d1y * d2x
        guard abs(denominator) > 1e-14 else {
            return nil
        }
        var t: Double = ((p3.x - p1.x) * d2y - (p3.y - p1.y) * d2x) / denominator
        var u: Double = ((p3.x - p1.x) * d1y - (p3.y - p1.y) * d1x) / denominator
        guard t >= -tolerance, t <= 1 + tolerance, u >= -tolerance, u <= 1 + tolerance else {
            return nil
        }
        t = min(1, max(0, t))
        u = min(1, max(0, u))
        return (t, u, CGPoint(x: p1.x + t * d1x, y: p1.y + t * d1y))
    }

    // MARK: - Raw offset

    /// Shifts every edge of a counter-clockwise polygon to the left by `d` (negative = right).
    /// Outer corners get a round join, concave corners are trimmed to the crossing of the two
    /// shifted edges when there is one. The result may cross itself.
    private static func rawOffset(_ poly: [CGPoint], distance d: Double, tolerance: Double) -> [CGPoint] {

        let n = poly.count

        var dirs: [CGPoint] = []
        var offsetStart: [CGPoint] = []
        var offsetEnd: [CGPoint] = []
        dirs.reserveCapacity(n)
        offsetStart.reserveCapacity(n)
        offsetEnd.reserveCapacity(n)

        for i in 0..<n {
            let a = poly[i]
            let b = poly[(i + 1) % n]
            let length = hypot(b.x - a.x, b.y - a.y)
            let dir = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
            dirs.append(dir)
            let nx = -dir.y, ny = dir.x
            offsetStart.append(CGPoint(x: a.x + nx * d, y: a.y + ny * d))
            offsetEnd.append(CGPoint(x: b.x + nx * d, y: b.y + ny * d))
        }

        // turns[i] is the cross product of edge i and edge i+1, i.e. the corner after edge i.
        var turns: [Double] = []
        turns.reserveCapacity(n)
        for i in 0..<n {
            let j = (i + 1) % n
            turns.append(dirs[i].x * dirs[j].y - dirs[i].y * dirs[j].x)
        }

        // Concave corners (turn and offset side agree): trim to where the shifted edges cross.
        var trimPoint = [CGPoint?](repeating: nil, count: n)
        var trimParams = [(t: Double, u: Double)](repeating: (0, 0), count: n)
        for i in 0..<n {
            guard turns[i] * d >= -1e-12 else {
                continue
            }
            let j = (i + 1) % n
            if let hit = segmentIntersection(offsetStart[i], offsetEnd[i], offsetStart[j], offsetEnd[j], tolerance: 1e-9) {
                trimPoint[i] = hit.point
                trimParams[i] = (hit.t, hit.u)
            }
        }

        // An edge whose two trims have swapped places is left untrimmed instead.
        for i in 0..<n {
            let previous = (i + n - 1) % n
            if trimPoint[previous] != nil, trimPoint[i] != nil {
                let startParam = trimParams[previous].u // where on edge i the incoming trim lands
                let endParam = trimParams[i].t          // where on edge i the outgoing trim lands
                if startParam > endParam {
                    trimPoint[previous] = nil
                    trimPoint[i] = nil
                }
            }
        }

        var result: [CGPoint] = []
        result.reserveCapacity(n * 2)

        for i in 0..<n {
            let previous = (i + n - 1) % n
            let j = (i + 1) % n

            result.append(trimPoint[previous] ?? offsetStart[i])
            result.append(trimPoint[i] ?? offsetEnd[i])

            // Outer corner: round join around the original vertex.
            if trimPoint[i] == nil, turns[i] * d < -1e-12 {
                let vertex = poly[j]
                let u = CGPoint(x: offsetEnd[i].x - vertex.x, y: offsetEnd[i].y - vertex.y)
                let w = CGPoint(x: offsetStart[j].x - vertex.x, y: offsetStart[j].y - vertex.y)
                let startAngle = atan2(u.y, u.x)
                let endAngle = atan2(w.y, w.x)

                var sweep = endAngle - startAngle
                while sweep > .pi { sweep -= 2 * .pi }
                while sweep < -.pi { sweep += 2 * .pi }
                // The arc must turn the same way the corner does.
                if turns[i] > 0, sweep < 0 { sweep += 2 * .pi }
                if turns[i] < 0, sweep > 0 { sweep -= 2 * .pi }

                let steps = arcStepCount(radius: abs(d), sweep: abs(sweep), tolerance: tolerance)
                if steps > 1 {
                    for k in 1..<steps {
                        let angle = startAngle + sweep * Double(k) / Double(steps)
                        result.append(pointOnCircle(center: vertex, radius: abs(d), angle: angle))
                    }
                }
            }
        }

        return dedupe(result, epsilon: 1e-9)
    }

    // MARK: - Splitting at self-intersections

    /// Splits a closed polyline at every point where it crosses itself. Each piece runs from
    /// one crossing to the next. When there are no crossings, `pieces` is empty and
    /// `hadIntersections` is false.
    private static func splitAtSelfIntersections(_ loop: [CGPoint]) -> (pieces: [[CGPoint]], hadIntersections: Bool) {

        let n = loop.count
        var hits = [[(t: Double, point: CGPoint)]](repeating: [], count: n)
        var foundAny = false

        forEachCrossingCandidate(in: loop, closed: true) { i, j in
            let a = loop[i], b = loop[(i + 1) % n]
            let c = loop[j], d = loop[(j + 1) % n]
            if let hit = segmentIntersection(a, b, c, d, tolerance: 1e-9) {
                hits[i].append((hit.t, hit.point))
                hits[j].append((hit.u, hit.point))
                foundAny = true
            }
        }

        guard foundAny else {
            return ([], false)
        }

        // Original vertices interleaved with the crossings that fall on each edge, in order.
        var sequence: [(point: CGPoint, isNode: Bool)] = []
        for i in 0..<n {
            sequence.append((loop[i], false))
            for hit in hits[i].sorted(by: { $0.t < $1.t }) {
                sequence.append((hit.point, true))
            }
        }

        // Merge coincident neighbours, keeping the node flag.
        var merged: [(point: CGPoint, isNode: Bool)] = []
        for entry in sequence {
            if let last = merged.last, hypot(entry.point.x - last.point.x, entry.point.y - last.point.y) < 1e-9 {
                merged[merged.count - 1].isNode = last.isNode || entry.isNode
            } else {
                merged.append(entry)
            }
        }
        if merged.count > 1,
           let first = merged.first,
           let last = merged.last,
           hypot(first.point.x - last.point.x, first.point.y - last.point.y) < 1e-9 {
            merged.removeLast()
            merged[0].isNode = first.isNode || last.isNode
        }

        let count = merged.count
        var nodeIndices: [Int] = []
        for k in 0..<count where merged[k].isNode {
            nodeIndices.append(k)
        }
        guard !nodeIndices.isEmpty else {
            return ([], false)
        }

        var pieces: [[CGPoint]] = []
        for a in 0..<nodeIndices.count {
            let startIndex = nodeIndices[a]
            let endIndex = nodeIndices[(a + 1) % nodeIndices.count]
            var piece: [CGPoint] = [merged[startIndex].point]
            var k = startIndex
            while true {
                k = (k + 1) % count
                piece.append(merged[k].point)
                if k == endIndex {
                    break
                }
            }
            pieces.append(piece)
        }
        return (pieces, true)
    }

    /// Calls `body(i, j)` for every pair of non-adjacent edges whose x-ranges overlap
    /// (sweep along x, so shapes with many edges don't cost n^2 tests).
    private static func forEachCrossingCandidate(in points: [CGPoint], closed: Bool, _ body: (Int, Int) -> Void) {

        let pointCount = points.count
        let edgeCount = closed ? pointCount : pointCount - 1
        guard edgeCount >= 3 else {
            return
        }

        var minX = [Double](repeating: 0, count: edgeCount)
        var maxX = [Double](repeating: 0, count: edgeCount)
        for i in 0..<edgeCount {
            let a = points[i], b = points[(i + 1) % pointCount]
            minX[i] = min(a.x, b.x)
            maxX[i] = max(a.x, b.x)
        }
        let order = (0..<edgeCount).sorted { minX[$0] < minX[$1] }

        for oi in 0..<edgeCount {
            let i = order[oi]
            var oj = oi + 1
            while oj < edgeCount {
                let j = order[oj]
                if minX[j] > maxX[i] + 1e-9 {
                    break
                }
                oj += 1

                let low = min(i, j), high = max(i, j)
                let adjacent = (high - low == 1) || (closed && low == 0 && high == edgeCount - 1)
                if adjacent {
                    continue
                }
                body(i, j)
            }
        }
    }

    /// True when a closed polyline properly crosses itself (touching end to end doesn't count).
    private static func hasSelfCrossing(_ points: [CGPoint]) -> Bool {

        let n = points.count
        var crossing = false
        forEachCrossingCandidate(in: points, closed: true) { i, j in
            if crossing {
                return
            }
            let a = points[i], b = points[(i + 1) % n]
            let c = points[j], d = points[(j + 1) % n]
            if let hit = segmentIntersection(a, b, c, d, tolerance: 0) {
                let margin = 1e-9
                if hit.t > margin, hit.t < 1 - margin, hit.u > margin, hit.u < 1 - margin {
                    crossing = true
                }
            }
        }
        return crossing
    }

    // MARK: - Winding classification

    /// Winding number of `loop` around `p` (counter-clockwise loops wind +1 around their inside).
    private static func windingNumber(of p: CGPoint, in loop: [CGPoint]) -> Int {
        var winding = 0
        let n = loop.count
        for i in 0..<n {
            let a = loop[i]
            let b = loop[(i + 1) % n]
            let side = (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)
            if a.y <= p.y {
                if b.y > p.y, side > 0 {
                    winding += 1
                }
            } else {
                if b.y <= p.y, side < 0 {
                    winding -= 1
                }
            }
        }
        return winding
    }

    /// Decides whether a piece of the raw curve is part of the result's boundary:
    /// 1 = keep as is (result lies to its left), -1 = keep reversed (result lies to its
    /// right), 0 = drop.
    private static func classify(_ piece: [CGPoint], against raw: [CGPoint], probe: Double) -> Int {

        // Probe next to the longest edge; its direction is the least noisy.
        var longest = 0.0
        var longestIndex = -1
        for k in 0..<(piece.count - 1) {
            let length = hypot(piece[k + 1].x - piece[k].x, piece[k + 1].y - piece[k].y)
            if length > longest {
                longest = length
                longestIndex = k
            }
        }
        guard longestIndex >= 0, longest > 1e-12 else {
            return 0
        }

        let a = piece[longestIndex]
        let b = piece[longestIndex + 1]
        let midX = (a.x + b.x) / 2, midY = (a.y + b.y) / 2
        let nx = -(b.y - a.y) / longest, ny = (b.x - a.x) / longest

        let left = windingNumber(of: CGPoint(x: midX + nx * probe, y: midY + ny * probe), in: raw)
        let right = windingNumber(of: CGPoint(x: midX - nx * probe, y: midY - ny * probe), in: raw)

        if left > 0, right <= 0 {
            return 1
        }
        if right > 0, left <= 0 {
            return -1
        }
        return 0
    }

    // MARK: - Chaining

    private struct PointKey: Hashable {
        let x: Int64
        let y: Int64

        init(_ p: CGPoint) {
            x = Int64((p.x / 1e-6).rounded())
            y = Int64((p.y / 1e-6).rounded())
        }
    }

    /// Joins pieces end to start into closed loops. Where several pieces leave the same point
    /// (the result touches itself), the sharpest right turn is taken, which keeps touching
    /// lobes as separate simple loops.
    private static func chain(_ pieces: [[CGPoint]]) -> [[CGPoint]] {

        var startingAt: [PointKey: [Int]] = [:]
        for (index, piece) in pieces.enumerated() {
            startingAt[PointKey(piece[0]), default: []].append(index)
        }

        var used = [Bool](repeating: false, count: pieces.count)
        var loops: [[CGPoint]] = []

        for first in 0..<pieces.count where !used[first] {
            var loop: [CGPoint] = []
            var current = first
            let startKey = PointKey(pieces[first][0])
            var closed = true

            while true {
                used[current] = true
                loop.append(contentsOf: pieces[current].dropLast())
                let endKey = PointKey(pieces[current][pieces[current].count - 1])
                if endKey == startKey {
                    break
                }

                let candidates = (startingAt[endKey] ?? []).filter { !used[$0] }
                if candidates.isEmpty {
                    closed = false
                    break
                }
                if candidates.count == 1 {
                    current = candidates[0]
                    continue
                }

                let piece = pieces[current]
                let incoming = CGPoint(x: piece[piece.count - 1].x - piece[piece.count - 2].x,
                                       y: piece[piece.count - 1].y - piece[piece.count - 2].y)
                var best = candidates[0]
                var bestAngle = Double.infinity
                for candidate in candidates {
                    let q = pieces[candidate]
                    let outgoing = CGPoint(x: q[1].x - q[0].x, y: q[1].y - q[0].y)
                    // Positive = left turn, negative = right turn.
                    let angle = atan2(incoming.x * outgoing.y - incoming.y * outgoing.x,
                                      incoming.x * outgoing.x + incoming.y * outgoing.y)
                    if angle < bestAngle {
                        bestAngle = angle
                        best = candidate
                    }
                }
                current = best
            }

            if closed, loop.count >= 3 {
                loops.append(dedupe(loop, epsilon: 1e-9))
            }
        }
        return loops
    }
}

// MARK: - Spatial index

/// Uniform grid over a closed polygon's edges, for "is any edge closer than r to this point?".
private struct SegmentGrid {

    private struct CellKey: Hashable {
        let x: Int
        let y: Int
    }

    private let points: [CGPoint]
    private let cellSize: Double
    private var cells: [CellKey: [Int]] = [:]

    init(polygon: [CGPoint], cellSize: Double) {
        self.points = polygon
        self.cellSize = max(cellSize, 1e-6)

        let n = polygon.count
        for i in 0..<n {
            let a = polygon[i]
            let b = polygon[(i + 1) % n]
            let x0 = cell(min(a.x, b.x)), x1 = cell(max(a.x, b.x))
            let y0 = cell(min(a.y, b.y)), y1 = cell(max(a.y, b.y))
            for cx in x0...x1 {
                for cy in y0...y1 {
                    cells[CellKey(x: cx, y: cy), default: []].append(i)
                }
            }
        }
    }

    private func cell(_ value: Double) -> Int {
        Int((value / cellSize).rounded(.down))
    }

    func hasSegment(closerThan radius: Double, to p: CGPoint) -> Bool {
        guard radius > 0 else {
            return false
        }
        let reach = Int((radius / cellSize).rounded(.up))
        let cx = cell(p.x), cy = cell(p.y)
        let n = points.count
        var seen = Set<Int>()
        for gx in (cx - reach)...(cx + reach) {
            for gy in (cy - reach)...(cy + reach) {
                guard let indices = cells[CellKey(x: gx, y: gy)] else {
                    continue
                }
                for i in indices where seen.insert(i).inserted {
                    if distance(from: p, toSegmentFrom: points[i], to: points[(i + 1) % n]) < radius {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func distance(from p: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-18 else {
            return hypot(p.x - a.x, p.y - a.y)
        }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
