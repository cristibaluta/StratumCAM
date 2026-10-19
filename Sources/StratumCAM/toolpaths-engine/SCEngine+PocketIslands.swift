//
//  SCEngine+PocketIslands.swift
//  StratumCAM
//
//  Island handling for concentric pockets. An island can be any closed outline of lines
//  and arcs. Its keep-out zone is that outline offset outward by the tool radius: the
//  tool centre must stay outside the zone, and cutting along the zone's edge is what
//  leaves the island standing.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// A closed loop the tool centre must stay outside of.
    struct PocketIslandZone {
        /// The island outline offset outward by the tool radius, oriented clockwise
        /// (climb direction for an outside profile).
        let loop: [SC.Segment]
    }

    // MARK: - Zones

    /// Turns island contours into keep-out zones, validating that they sit inside the wall
    /// ring and clear of each other (the tool must fit around every island).
    func islandZones(_ islands: [SC.Contour], toolRadius: Double, wallRing: [SC.Segment]) throws -> [PocketIslandZone] {
        var zones: [PocketIslandZone] = []

        for island in islands {
            let segments = island.linearizedSegments
            guard island.isClosed, !segments.isEmpty else {
                throw SC.Error.invalidParameter("islands must be closed contours")
            }

            let outline = offsetContour(segments, side: .outside, toolRadius: toolRadius, isClosed: true)
            // `offsetContour` hands its input back when it can't offset it.
            guard !outline.isEmpty, outline != segments else {
                throw SC.Error.invalidParameter("island outline can't be offset by the tool radius")
            }

            let clockwise = OffsetTools.isCCWWinding(outline)
                ? outline.reversed().map { $0.reversed }
                : outline
            zones.append(PocketIslandZone(loop: clockwise))
        }

        let wallSamples = loopSamples(wallRing, steps: 8)

        for (index, zone) in zones.enumerated() {
            // The whole zone has to be inside the wall ring (touching it is fine)...
            for point in loopSamples(zone.loop, steps: 8) {
                guard isInsideLoop(point, loop: wallRing) || distance(from: point, toLoop: wallRing) < 1e-6 else {
                    throw SC.Error.invalidParameter("island too close to the pocket wall for the tool to fit")
                }
            }
            // ...and the wall must not poke into it.
            for point in wallSamples where isInside(point, zone: zone) {
                throw SC.Error.invalidParameter("island too close to the pocket wall for the tool to fit")
            }

            for other in zones[(index + 1)...] {
                let overlaps = loopSamples(zone.loop, steps: 8).contains { isInside($0, zone: other) }
                    || loopSamples(other.loop, steps: 8).contains { isInside($0, zone: zone) }
                guard !overlaps else {
                    throw SC.Error.invalidParameter("islands are closer together than the tool can fit")
                }
            }
        }

        return zones
    }

    // MARK: - Ring clipping and chaining

    /// Clips every ring against the island zones and chains the results into groups.
    /// A ring crossing a zone follows the zone's edge instead of cutting through the
    /// island, so every clipped ring is still made of closed loops. Each island's own
    /// wall is finished with a full loop at the end. Consecutive loops are chained with a
    /// straight link when that link stays clear of every zone; otherwise a new group starts
    /// (plunged and retracted separately). With `wallRing`, a link that would leave the pocket
    /// also starts a new group.
    func islandRingGroups(rings: [[SC.Segment]], zones: [PocketIslandZone], wallRing: [SC.Segment]? = nil) -> [[SC.Segment]] {
        var groups: [[SC.Segment]] = []
        var current: [SC.Segment] = []

        func append(_ loop: [SC.Segment]) {
            guard let start = loop.first?.startPoint else {
                return
            }
            if let end = current.last?.endPoint {
                if hypot(start.x - end.x, start.y - end.y) <= 1e-6 {
                    current.append(contentsOf: loop)
                    return
                }
                let link = SC.Segment.line(start: end, end: start)
                let linkCrossesZone = zones.contains { zone in
                    split(link, by: zone).contains { isInside(midpoint(of: $0), zone: zone) }
                }
                // A link between two rings can also leave the pocket (a concave wall).
                let linkLeavesWall = wallRing.map { !linkStaysInside(from: end, to: start, wallRing: $0) } ?? false
                if !linkCrossesZone && !linkLeavesWall {
                    current.append(link)
                    current.append(contentsOf: loop)
                    return
                }
                groups.append(current)
            }
            current = loop
        }

        for ring in rings {
            for loop in clippedRingLoops(ring, zones: zones) {
                append(loop)
            }
        }

        // Island walls: outside profile, climb = clockwise (the zone loops are clockwise).
        // Start each wall at the corner nearest to where the tool already is.
        for zone in zones {
            append(rotated(zone.loop, nearestTo: current.last?.endPoint))
        }

        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    /// `loop` rotated so it starts at the segment start nearest to `point`.
    private func rotated(_ loop: [SC.Segment], nearestTo point: CGPoint?) -> [SC.Segment] {
        guard let point, loop.count > 1 else {
            return loop
        }
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, segment) in loop.enumerated() {
            let start = segment.startPoint
            let d = hypot(start.x - point.x, start.y - point.y)
            if d < bestDistance {
                bestDistance = d
                best = index
            }
        }
        return Array(loop[best...] + loop[..<best])
    }

    /// `ring` clipped against the zones: the parts inside any zone are dropped and the gaps
    /// are bridged by walking the zone's edge, keeping the cleared region on the same side
    /// as the ring does. A ring that an island only cuts into stays one loop; an island that
    /// spans the ring splits it into several. Returns `[ring]` when nothing is clipped and
    /// `[]` when the whole ring lies inside zones.
    private func clippedRingLoops(_ ring: [SC.Segment], zones: [PocketIslandZone]) -> [[SC.Segment]] {
        var pieces = ring
        for zone in zones {
            pieces = pieces.flatMap { split($0, by: zone) }
        }

        let kept = pieces.map { piece -> Bool in
            let middle = midpoint(of: piece)
            return !zones.contains { isInside(middle, zone: $0) }
        }

        if kept.allSatisfy({ $0 }) {
            return [ring]
        }
        let n = pieces.count
        guard let startIndex = (0..<n).first(where: { kept[$0] && !kept[($0 + n - 1) % n] }) else {
            return []
        }

        // Runs of ring pieces that survive, in ring order. Each run starts where the ring
        // comes out of a zone and ends where it goes into one.
        var builtRuns: [[SC.Segment]] = []
        var offset = 0
        while offset < n {
            let index = (startIndex + offset) % n
            if kept[index] {
                var run: [SC.Segment] = []
                while offset < n, kept[(startIndex + offset) % n] {
                    run.append(pieces[(startIndex + offset) % n])
                    offset += 1
                }
                builtRuns.append(run)
            } else {
                offset += 1
            }
        }
        let runs = builtRuns

        // The cleared region lies to the left of a counter-clockwise ring and to the right of
        // a clockwise one. Zone loops run clockwise, so going round a zone with the region on
        // the left means following the loop forward; on the right, backward.
        let followsZoneForward = OffsetTools.isCCWWinding(ring)
        let tolerance = 1e-4

        /// Where the tool goes after run `i`: along the zone edge to the first run that
        /// starts on it, which is not necessarily the next run round the ring.
        func link(after i: Int) -> (index: Int, connector: [SC.Segment]) {
            let leavePoint = runs[i][runs[i].count - 1].endPoint

            var best: (length: Double, index: Int, path: [SC.Segment])?
            if let zone = zones.first(where: { distance(from: leavePoint, toLoop: $0.loop) < tolerance }) {
                for j in runs.indices {
                    let entry = runs[j][0].startPoint
                    guard distance(from: entry, toLoop: zone.loop) < tolerance else {
                        continue
                    }
                    if hypot(leavePoint.x - entry.x, leavePoint.y - entry.y) <= 1e-6 {
                        best = (0, j, [])
                        break
                    }
                    guard let paths = zonePaths(zone.loop, from: leavePoint, to: entry) else {
                        continue
                    }
                    let path = followsZoneForward ? paths.forward : paths.backward
                    let length = path.reduce(0.0) { $0 + $1.pathLength }
                    if best == nil || length < best!.length {
                        best = (length, j, path)
                    }
                }
            }
            if let best {
                return (best.index, best.path)
            }

            // No zone edge to follow (shouldn't happen): straight to the next run.
            let j = (i + 1) % runs.count
            let entry = runs[j][0].startPoint
            let gap = hypot(leavePoint.x - entry.x, leavePoint.y - entry.y)
            return (j, gap > 1e-6 ? [.line(start: leavePoint, end: entry)] : [])
        }

        var used = Array(repeating: false, count: runs.count)
        var loops: [[SC.Segment]] = []
        for i in runs.indices where !used[i] {
            var loop: [SC.Segment] = []
            var current = i
            while !used[current] {
                used[current] = true
                let next = link(after: current)
                loop.append(contentsOf: runs[current])
                loop.append(contentsOf: next.connector)
                current = next.index
            }
            loops.append(loop)
        }
        return loops
    }

    /// Both ways round the closed `loop` from `from` to `to`: `forward` follows the loop's
    /// own direction, `backward` goes the other way (already reversed to run from `from`).
    private func zonePaths(_ loop: [SC.Segment], from: CGPoint, to: CGPoint) -> (forward: [SC.Segment], backward: [SC.Segment])? {
        let tolerance = 1e-4

        var pieces: [SC.Segment] = []
        for segment in loop {
            var parameters: [Double] = []
            for target in [from, to] {
                if let found = parameter(of: target, on: segment, tolerance: tolerance) {
                    parameters.append(found)
                }
            }
            pieces.append(contentsOf: split(segment, atParameters: parameters))
        }

        func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
            hypot(a.x - b.x, a.y - b.y) < tolerance
        }

        let n = pieces.count
        guard let first = (0..<n).first(where: { near(pieces[$0].startPoint, from) }) else {
            return nil
        }

        var forward: [SC.Segment] = []
        var reachedEnd = false
        var consumed = 0
        while consumed < n {
            let piece = pieces[(first + consumed) % n]
            forward.append(piece)
            consumed += 1
            if near(piece.endPoint, to) {
                reachedEnd = true
                break
            }
        }
        guard reachedEnd else {
            return nil
        }

        // What's left runs from `to` on round to `from`; reversed, it runs from `from` to `to`.
        var rest: [SC.Segment] = []
        while consumed < n {
            rest.append(pieces[(first + consumed) % n])
            consumed += 1
        }
        let backward = rest.reversed().map { $0.reversed }
        guard !forward.isEmpty, !backward.isEmpty else {
            return nil
        }
        return (forward, backward)
    }

    // MARK: - Point and loop tests

    /// True when `point` is strictly inside `zone` (on its edge doesn't count).
    private func isInside(_ point: CGPoint, zone: PocketIslandZone) -> Bool {
        isInsideLoop(point, loop: zone.loop) && distance(from: point, toLoop: zone.loop) > 1e-6
    }

    func distance(from point: CGPoint, toLoop loop: [SC.Segment]) -> Double {
        loop.reduce(Double.greatestFiniteMagnitude) { min($0, distance(from: point, to: $1)) }
    }

    /// Points along a closed loop, for checks that only need a dense sample.
    private func loopSamples(_ loop: [SC.Segment], steps: Int) -> [CGPoint] {
        var points: [CGPoint] = []
        for segment in loop {
            switch segment {
                case .line(let start, let end):
                    for k in 0..<steps {
                        let t = Double(k) / Double(steps)
                        points.append(CGPoint(x: start.x + t * (end.x - start.x), y: start.y + t * (end.y - start.y)))
                    }
                case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                    let sweep = SC.Segment.sweepAngle(start: startAngle, end: endAngle, isCCW: isCCW)
                    let direction: Double = isCCW ? 1 : -1
                    for k in 0..<steps {
                        let angle = startAngle + direction * sweep * Double(k) / Double(steps)
                        points.append(CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
                    }
            }
        }
        return points
    }

    /// Even-odd test of `point` against the closed `loop`, exact for arcs.
    ///
    /// A ray is cast towards +x. Every piece of the loop is monotone in y (arcs are cut at
    /// their top and bottom), and counts as crossing when `y` lies in its half-open y range,
    /// so rays through vertices, junctions or tangent points are counted correctly.
    func isInsideLoop(_ point: CGPoint, loop: [SC.Segment]) -> Bool {
        let y = point.y
        var crossings = 0

        for segment in loop {
            switch segment {
                case .line(let a, let b):
                    guard (a.y <= y) != (b.y <= y) else {
                        continue
                    }
                    let x = a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)
                    if x > point.x {
                        crossings += 1
                    }

                case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                    let total = SC.Segment.sweepAngle(start: startAngle, end: endAngle, isCCW: isCCW)
                    guard total > 1e-12 else {
                        continue
                    }
                    let direction: Double = isCCW ? 1 : -1

                    // y-monotone pieces: cut at the sweep offsets where the arc reaches +-pi/2.
                    var cuts: [Double] = [0, total]
                    for extreme in [Double.pi / 2, -Double.pi / 2] {
                        var offset = SC.Segment.sweepAngle(start: startAngle, end: extreme, isCCW: isCCW)
                        offset = offset.truncatingRemainder(dividingBy: 2 * Double.pi)
                        if offset < 0 {
                            offset += 2 * Double.pi
                        }
                        if offset > 1e-12, offset < total - 1e-12 {
                            cuts.append(offset)
                        }
                    }
                    cuts.sort()

                    for index in 0..<(cuts.count - 1) {
                        let a0 = startAngle + direction * cuts[index]
                        let a1 = startAngle + direction * cuts[index + 1]
                        let y0 = center.y + radius * sin(a0)
                        let y1 = center.y + radius * sin(a1)
                        guard (y0 <= y) != (y1 <= y) else {
                            continue
                        }
                        let dy = y - center.y
                        let dx = max(radius * radius - dy * dy, 0).squareRoot()
                        // A monotone piece lies in one half of the circle: right or left.
                        let side: Double = cos((a0 + a1) / 2) >= 0 ? 1 : -1
                        if center.x + side * dx > point.x {
                            crossings += 1
                        }
                    }
            }
        }
        return crossings % 2 == 1
    }

    // MARK: - Splitting segments at zone edges

    /// Splits `segment` at every point where it crosses the zone's edge.
    private func split(_ segment: SC.Segment, by zone: PocketIslandZone) -> [SC.Segment] {
        let parameters = zone.loop.flatMap { intersectionParameters(of: segment, with: $0) }
        return split(segment, atParameters: parameters)
    }

    /// Cuts `segment` at the given parameters: `t` in 0...1 along a line, the swept angle
    /// from the start along an arc. Parameters at or beyond the ends are ignored.
    func split(_ segment: SC.Segment, atParameters raw: [Double]) -> [SC.Segment] {
        switch segment {
            case .line(let a, let b):
                let ts = distinctSorted(raw.filter { $0 > 1e-9 && $0 < 1 - 1e-9 })
                guard !ts.isEmpty else {
                    return [segment]
                }
                var points: [CGPoint] = [a]
                points.append(contentsOf: ts.map { CGPoint(x: a.x + $0 * (b.x - a.x), y: a.y + $0 * (b.y - a.y)) })
                points.append(b)
                return (0..<(points.count - 1)).map { .line(start: points[$0], end: points[$0 + 1]) }

            case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                let total = SC.Segment.sweepAngle(start: startAngle, end: endAngle, isCCW: isCCW)
                let sweeps = distinctSorted(raw.filter { $0 > 1e-9 && $0 < total - 1e-9 })
                guard !sweeps.isEmpty else {
                    return [segment]
                }
                let direction: Double = isCCW ? 1 : -1
                let boundaries = [0.0] + sweeps + [total]
                return (0..<(boundaries.count - 1)).map { index in
                    .arc(center: center,
                         radius: radius,
                         startAngle: startAngle + direction * boundaries[index],
                         endAngle: startAngle + direction * boundaries[index + 1],
                         isCCW: isCCW)
                }
        }
    }

    /// `values` sorted, with entries closer than 1e-9 to the previous one dropped.
    private func distinctSorted(_ values: [Double]) -> [Double] {
        var result: [Double] = []
        for value in values.sorted() {
            if let last = result.last, value - last <= 1e-9 {
                continue
            }
            result.append(value)
        }
        return result
    }

    /// Where `point` lies on `segment`, as a split parameter, or `nil` if it isn't on it.
    private func parameter(of point: CGPoint, on segment: SC.Segment, tolerance: Double) -> Double? {
        switch segment {
            case .line(let a, let b):
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                guard len2 > 1e-18 else {
                    return nil
                }
                let t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / len2
                guard t >= -1e-9, t <= 1 + 1e-9,
                      hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy)) < tolerance else {
                    return nil
                }
                return t

            case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                guard abs(hypot(point.x - center.x, point.y - center.y) - radius) < tolerance else {
                    return nil
                }
                let angle = atan2(point.y - center.y, point.x - center.x)
                guard EngineTools.angleWithinSweep(angle, start: startAngle, end: endAngle, isCCW: isCCW) else {
                    return nil
                }
                return normalizedSweep(from: startAngle, to: angle, isCCW: isCCW)
        }
    }

    /// Sweep from `start` to `angle` in the arc's direction, folded into one turn.
    private func normalizedSweep(from start: Double, to angle: Double, isCCW: Bool) -> Double {
        let twoPi = 2 * Double.pi
        var sweep = SC.Segment.sweepAngle(start: start, end: angle, isCCW: isCCW).truncatingRemainder(dividingBy: twoPi)
        if sweep < 0 {
            sweep += twoPi
        }
        return sweep
    }

    /// Split parameters of `segment` at its crossings with `other` (both bounded to their
    /// own extent). The parameter is `t` for a line and the swept angle for an arc.
    func intersectionParameters(of segment: SC.Segment, with other: SC.Segment) -> [Double] {
        switch (segment, other) {

            case (.line(let a, let b), .line(let c, let d)):
                let r = CGPoint(x: b.x - a.x, y: b.y - a.y)
                let s = CGPoint(x: d.x - c.x, y: d.y - c.y)
                let denominator = r.x * s.y - r.y * s.x
                guard abs(denominator) > 1e-12 else {
                    return [] // parallel or collinear
                }
                let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / denominator
                let u = ((c.x - a.x) * r.y - (c.y - a.y) * r.x) / denominator
                guard u >= -1e-9, u <= 1 + 1e-9 else {
                    return []
                }
                return [t]

            case (.line(let a, let b), .arc(let center, let radius, let startAngle, let endAngle, let isCCW)):
                let dx = b.x - a.x, dy = b.y - a.y
                let fx = a.x - center.x, fy = a.y - center.y
                let qa = dx * dx + dy * dy
                let qb = 2 * (fx * dx + fy * dy)
                let qc = fx * fx + fy * fy - radius * radius
                let discriminant = qb * qb - 4 * qa * qc
                guard qa > 1e-12, discriminant > 0 else {
                    return []
                }
                let root = discriminant.squareRoot()
                return [(-qb - root) / (2 * qa), (-qb + root) / (2 * qa)].filter { t in
                    let angle = atan2(a.y + t * dy - center.y, a.x + t * dx - center.x)
                    return EngineTools.angleWithinSweep(angle, start: startAngle, end: endAngle, isCCW: isCCW)
                }

            case (.arc(let center, let radius, let startAngle, let endAngle, let isCCW), .line(let c, let d)):
                let dx = d.x - c.x, dy = d.y - c.y
                let fx = c.x - center.x, fy = c.y - center.y
                let qa = dx * dx + dy * dy
                let qb = 2 * (fx * dx + fy * dy)
                let qc = fx * fx + fy * fy - radius * radius
                let discriminant = qb * qb - 4 * qa * qc
                guard qa > 1e-12, discriminant > 0 else {
                    return []
                }
                let root = discriminant.squareRoot()
                var sweeps: [Double] = []
                for u in [(-qb - root) / (2 * qa), (-qb + root) / (2 * qa)] where u >= -1e-9 && u <= 1 + 1e-9 {
                    let angle = atan2(c.y + u * dy - center.y, c.x + u * dx - center.x)
                    if EngineTools.angleWithinSweep(angle, start: startAngle, end: endAngle, isCCW: isCCW) {
                        sweeps.append(normalizedSweep(from: startAngle, to: angle, isCCW: isCCW))
                    }
                }
                return sweeps

            case (.arc(let center, let radius, let startAngle, let endAngle, let isCCW),
                  .arc(let otherCenter, let otherRadius, let otherStart, let otherEnd, let otherIsCCW)):
                let dx = otherCenter.x - center.x, dy = otherCenter.y - center.y
                let d = hypot(dx, dy)
                guard d > 1e-9, d < radius + otherRadius, d > abs(radius - otherRadius) else {
                    return []
                }
                let along = (radius * radius - otherRadius * otherRadius + d * d) / (2 * d)
                let heightSquared = radius * radius - along * along
                guard heightSquared > 1e-12 else {
                    return []
                }
                let height = heightSquared.squareRoot()
                let ux = dx / d, uy = dy / d
                let base = CGPoint(x: center.x + along * ux, y: center.y + along * uy)
                let candidates = [CGPoint(x: base.x - height * uy, y: base.y + height * ux),
                                  CGPoint(x: base.x + height * uy, y: base.y - height * ux)]

                var sweeps: [Double] = []
                for candidate in candidates {
                    let onOther = atan2(candidate.y - otherCenter.y, candidate.x - otherCenter.x)
                    guard EngineTools.angleWithinSweep(onOther, start: otherStart, end: otherEnd, isCCW: otherIsCCW) else {
                        continue
                    }
                    let angle = atan2(candidate.y - center.y, candidate.x - center.x)
                    if EngineTools.angleWithinSweep(angle, start: startAngle, end: endAngle, isCCW: isCCW) {
                        sweeps.append(normalizedSweep(from: startAngle, to: angle, isCCW: isCCW))
                    }
                }
                return sweeps
        }
    }
}
