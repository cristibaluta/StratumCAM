//
//  SCEngine+PocketAdaptive.swift
//  StratumCAM
//
//  Adaptive clearing for pockets (`.adaptive`), modelled on what CAM packages call
//  "2D adaptive clearing":
//
//   1. Helix in the middle of the largest free area (the pole of inaccessibility already
//      used by the concentric pattern), then a spiral that grows from the helix to the biggest
//      circle that touches nothing.
//   2. What is left of the pocket is cleared by a wavefront that moves outward from that
//      circle. Every pass is the line of constant distance from what is already cleared, one
//      `stepover` further than the previous one, so the radial engagement stays about
//      `optimalLoad` instead of growing in corners.
//   3. The wavefront splits wherever the pocket does (the arms of a star, the two sides of
//      an island). Each branch is cleared completely, tip to tip, before the next one is
//      started, instead of taking one bite out of every branch in turn.
//   4. One last pass along the wall and around the islands cleans up the scallops.
//
//  The distance field is computed on a grid (fast marching, so it respects islands and
//  concave walls: distance is measured around obstacles, not through them). Only the shape of
//  the passes comes from the grid; the walls and the island zones themselves stay exact
//  lines and arcs, and the passes are extended onto them.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// One continuous stretch of adaptive toolpath: entered once (plunge, ramp or helix) and
    /// followed without lifting.
    struct AdaptiveGroup {
        var segments: [SC.Segment]
        /// Where a helix entry goes: the group starts with a full circle around `center`.
        var helix: (center: CGPoint, radius: Double, startAngle: Double, isCCW: Bool)?
    }

    /// Radial engagement the adaptive pattern aims for.
    func adaptiveStepover(settings: SC.AdaptiveSettings, cutting: SC.CuttingData, tool: SC.ToolParams) -> Double {
        var value = settings.optimalLoad
        if value <= 1e-6 {
            value = cutting.maxOptimalLoad
        }
        if value <= 1e-6 {
            value = cutting.stepoverPercentage * tool.diameter
        }
        return min(max(value, 0.02 * tool.diameter), 0.95 * tool.diameter)
    }

    /// Builds the adaptive toolpath for the tool-centre region bounded by `wallRing` and the
    /// island `zones`. Returns the groups in cutting order, or `nil` when the region has
    /// no room for the tool at all.
    ///
    /// - Parameters:
    ///   - wallRing: the pocket wall already offset by the tool radius, oriented for the
    ///     requested direction (counter-clockwise = climb).
    ///   - stepover: radial engagement in mm.
    func adaptiveGroups(wallRing: [SC.Segment],
                        zones: [PocketIslandZone],
                        toolRadius: Double,
                        stepover: Double) -> [AdaptiveGroup]? {
        guard let pole = pocketCenter(wallRing: wallRing, zones: zones), pole.radius > 1e-3, stepover > 1e-6 else {
            return nil
        }
        let clearing = AdaptiveClearing(engine: self,
                                        wallRing: wallRing,
                                        zones: zones,
                                        toolRadius: toolRadius,
                                        stepover: stepover)
        return clearing.run(firstPole: pole)
    }

    /// Every x where a horizontal line at `y` crosses one of `loops`, counting a crossing when
    /// `y` lies in a piece's half-open y range, so parity is right even when the line goes
    /// through a vertex. Same rule as `isInsideLoop`, but returns the crossings.
    func loopCrossings(atY y: Double, loops: [[SC.Segment]]) -> [Double] {
        var xs: [Double] = []
        for loop in loops {
            for segment in loop {
                switch segment {
                    case .line(let a, let b):
                        guard (a.y <= y) != (b.y <= y) else {
                            continue
                        }
                        xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))

                    case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                        let total = SC.Segment.sweepAngle(start: startAngle, end: endAngle, isCCW: isCCW)
                        guard total > 1e-12 else {
                            continue
                        }
                        let direction: Double = isCCW ? 1 : -1
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
                            let side: Double = cos((a0 + a1) / 2) >= 0 ? 1 : -1
                            xs.append(center.x + side * dx)
                        }
                }
            }
        }
        return xs
    }
}

// MARK: - The algorithm

private final class AdaptiveClearing {

    let engine: SCEngine
    let wallRing: [SC.Segment]
    let zones: [SCEngine.PocketIslandZone]
    let toolRadius: Double
    let stepover: Double

    /// True when the tool travels counter-clockwise around the pole (climb in a pocket).
    let ccw: Bool
    let boundaryLoops: [[SC.Segment]]

    // Grid: vertices at (x0 + i*h, y0 + j*h)
    var h = 0.0
    var x0 = 0.0
    var y0 = 0.0
    var nx = 0
    var ny = 0
    var inRegion: [Bool] = []
    var distance: [Double] = []
    var known: [Bool] = []
    var reached: [Bool] = []
    var cleared: [Bool] = []

    struct Piece {
        var band: Int
        var vertices: [Int32]
        var children: [Int] = []
        var parentsLeft = 0
        var curves: [[SC.Segment]]?
    }
    var pieces: [Piece] = []

    init(engine: SCEngine, wallRing: [SC.Segment], zones: [SCEngine.PocketIslandZone], toolRadius: Double, stepover: Double) {
        self.engine = engine
        self.wallRing = wallRing
        self.zones = zones
        self.toolRadius = toolRadius
        self.stepover = stepover
        self.ccw = OffsetTools.isCCWWinding(wallRing)
        self.boundaryLoops = [wallRing] + zones.map { $0.loop }
        buildGrid()
    }

    // MARK: Grid

    private func buildGrid() {
        let box = wallRing.boundingBox
        let width = box.maxX - box.minX
        let height = box.maxY - box.minY
        let maxVertices = 1_500_000.0
        let fine = stepover / 5
        let coarse = (max(width, 1e-6) * max(height, 1e-6) / maxVertices).squareRoot()
        h = max(fine, coarse)
        h = max(h, 1e-4)

        nx = Int((width / h).rounded(.up)) + 5
        ny = Int((height / h).rounded(.up)) + 5
        // Odd offsets keep grid rows off vertices and axis-aligned edges of the outline.
        x0 = box.minX - 2 * h - 0.0137 * h
        y0 = box.minY - 2 * h - 0.0291 * h

        let count = nx * ny
        inRegion = Array(repeating: false, count: count)
        distance = Array(repeating: Double.infinity, count: count)
        known = Array(repeating: false, count: count)
        reached = Array(repeating: false, count: count)
        cleared = Array(repeating: false, count: count)

        for j in 0..<ny {
            let y = y0 + Double(j) * h
            let xs = engine.loopCrossings(atY: y, loops: boundaryLoops).sorted()
            var k = 0
            while k + 1 < xs.count {
                let first = max(0, Int(((xs[k] - x0) / h).rounded(.up)))
                let last = min(nx - 1, Int(((xs[k + 1] - x0) / h).rounded(.down)))
                if first <= last {
                    for i in first...last {
                        inRegion[j * nx + i] = true
                    }
                }
                k += 2
            }
        }
    }

    @inline(__always) private func index(_ i: Int, _ j: Int) -> Int { j * nx + i }

    private func point(_ v: Int) -> CGPoint {
        CGPoint(x: x0 + Double(v % nx) * h, y: y0 + Double(v / nx) * h)
    }

    private func nearestVertex(to p: CGPoint) -> Int? {
        let i = Int(((p.x - x0) / h).rounded())
        let j = Int(((p.y - y0) / h).rounded())
        guard i >= 0, i < nx, j >= 0, j < ny else {
            return nil
        }
        return index(i, j)
    }

    // MARK: Driver

    func run(firstPole: SCEngine.PocketCenter) -> [SCEngine.AdaptiveGroup]? {
        var groups: [SCEngine.AdaptiveGroup] = []
        var pole = firstPole
        var position: CGPoint?
        var safety = 0

        while safety < 16 {
            safety += 1
            guard let component = clearComponent(pole: pole) else {
                break
            }
            groups.append(contentsOf: component.groups)
            position = component.end

            // Anything of the region the wavefront didn't reach is a separate area.
            guard let next = unreachedPole() else {
                break
            }
            pole = next
        }
        guard var last = groups.popLast(), var here = position else {
            return nil
        }

        // Finishing: the wall, then around every island. Zone loops are stored clockwise
        // (climb for an outside profile); flip them for conventional.
        var remaining: [[SC.Segment]] = [orientedLoop(wallRing, counterClockwise: ccw)]
        for zone in zones {
            remaining.append(ccw ? zone.loop : zone.loop.reversed().map { $0.reversed })
        }
        while !remaining.isEmpty {
            var best = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (k, loop) in remaining.enumerated() {
                if let near = engine.nearestPoint(onLoop: loop, to: here) {
                    let d = hypot(near.x - here.x, near.y - here.y)
                    if d < bestDistance {
                        bestDistance = d
                        best = k
                    }
                }
            }
            let loop = remaining.remove(at: best)
            guard let start = engine.nearestPoint(onLoop: loop, to: here) else {
                continue
            }
            let rotated = engine.rotatedLoop(loop, startingAt: start)
            if bestDistance > 1e-6 {
                // A short hop over cleared ground stays in the cut; a long one is quicker
                // as a lift, move and plunge.
                if bestDistance <= 12 * toolRadius, linkIsSafe(from: here, to: start, allowed: nil) {
                    last.segments.append(.line(start: here, end: start))
                } else if bestDistance <= 12 * toolRadius, let route = routeThroughCleared(from: here, to: start, allowed: nil) {
                    last.segments.append(contentsOf: route)
                } else {
                    groups.append(last)
                    last = SCEngine.AdaptiveGroup(segments: [], helix: nil)
                }
            }
            last.segments.append(contentsOf: rotated)
            here = rotated.last?.endPoint ?? start
        }
        groups.append(last)
        return groups.filter { !$0.segments.isEmpty }
    }

    private func orientedLoop(_ loop: [SC.Segment], counterClockwise: Bool) -> [SC.Segment] {
        OffsetTools.isCCWWinding(loop) == counterClockwise ? loop : loop.reversed().map { $0.reversed }
    }

    /// The point of the not yet reached part of the region with the most room around it.
    private func unreachedPole() -> SCEngine.PocketCenter? {
        var best: (v: Int, clearance: Double)?
        var v = 0
        while v < inRegion.count {
            if inRegion[v], !reached[v] {
                let c = engine.clearance(at: point(v), wallRing: wallRing, zones: zones)
                if best == nil || c > best!.clearance {
                    best = (v, c)
                }
            }
            v += 2
        }
        guard let best, best.clearance > max(1.5 * h, 0.02 * toolRadius) else {
            return nil
        }
        return SCEngine.PocketCenter(point: point(best.v), radius: best.clearance)
    }

    // MARK: One connected area

    private func clearComponent(pole: SCEngine.PocketCenter) -> (groups: [SCEngine.AdaptiveGroup], end: CGPoint)? {

        currentPole = pole
        propagateDistance(from: pole)
        for v in 0..<known.count where known[v] && distance[v] <= 0 {
            cleared[v] = true // the free disk
        }
        buildPieces()
        var finished: [SCEngine.AdaptiveGroup] = []

        // Roots: pieces touching the disk. The first one decides where the spiral ends.
        var ready: [Int] = pieces.indices.filter { pieces[$0].parentsLeft == 0 }
        var segments: [SC.Segment] = []

        let helixRadius = min(RampTools.helixRadius(forToolRadius: toolRadius), pole.radius)

        // Leave pieces that have nothing to cut (too small to hold a pass) out of the way.
        func drainEmpty() {
            var changed = true
            while changed {
                changed = false
                for id in ready where curves(of: id).isEmpty {
                    finish(piece: id, ready: &ready)
                    changed = true
                    break
                }
            }
        }
        drainEmpty()

        var firstStart: CGPoint?
        if let first = ready.min(), let curve = curves(of: first).first {
            firstStart = curve.first?.startPoint
        }
        let startAngle: Double
        if let firstStart {
            startAngle = atan2(firstStart.y - pole.point.y, firstStart.x - pole.point.x)
        } else {
            startAngle = -Double.pi / 2
        }

        // Helix landing circle, spiral out, closing circle.
        segments.append(contentsOf: centreSegments(pole: pole, helixRadius: helixRadius, startAngle: startAngle))
        var position = segments.last?.endPoint ?? pole.point
        var group = SCEngine.AdaptiveGroup(segments: segments,
                                           helix: (pole.point, helixRadius, startAngle, ccw))
        var lastCurve: [SC.Segment] = []
        var lastPiece: Int?

        while true {
            drainEmpty()
            guard let id = nextPiece(from: position, ready: ready, after: lastPiece) else {
                break
            }
            var todo = curves(of: id)
            while !todo.isEmpty {
                // Next curve: the one that starts nearest to the tool.
                var best = 0
                var bestDistance = Double.greatestFiniteMagnitude
                for (k, curve) in todo.enumerated() {
                    if let start = curve.first?.startPoint {
                        let d = hypot(start.x - position.x, start.y - position.y)
                        if d < bestDistance {
                            bestDistance = d
                            best = k
                        }
                    }
                }
                let curve = todo.remove(at: best)
                guard let start = curve.first?.startPoint, let end = curve.last?.endPoint else {
                    continue
                }
                if bestDistance > 1e-6 {
                    if linkIsSafe(from: position, to: start, allowed: id) {
                        group.segments.append(.line(start: position, end: start))
                    } else if !lastCurve.isEmpty,
                              let back = lastCurve.first?.startPoint,
                              linkIsSafe(from: back, to: start, allowed: id) {
                        // Walk back along the pass just cut (it is clear air now), then across.
                        group.segments.append(contentsOf: lastCurve.reversed().map { $0.reversed })
                        if hypot(back.x - start.x, back.y - start.y) > 1e-6 {
                            group.segments.append(.line(start: back, end: start))
                        }
                    } else if let route = routeThroughCleared(from: position, to: start, allowed: id) {
                        // Round the obstacle over ground that is already clear.
                        group.segments.append(contentsOf: route)
                    } else {
                        // Nothing safe connects them: lift, move and plunge again.
                        finished.append(group)
                        group = SCEngine.AdaptiveGroup(segments: [], helix: nil)
                    }
                }
                group.segments.append(contentsOf: curve)
                position = end
                lastCurve = curve
            }
            lastPiece = id
            finish(piece: id, ready: &ready)
        }

        return (finished + [group], position)
    }

    // MARK: Centre: helix circle, spiral, closing circle

    private func centreSegments(pole: SCEngine.PocketCenter, helixRadius: Double, startAngle: Double) -> [SC.Segment] {
        let c = pole.point
        let sign: Double = ccw ? 1 : -1

        func circle(_ r: Double) -> [SC.Segment] {
            [.arc(center: c, radius: r, startAngle: startAngle, endAngle: startAngle + sign * Double.pi, isCCW: ccw),
             .arc(center: c, radius: r, startAngle: startAngle + sign * Double.pi, endAngle: startAngle + sign * 2 * Double.pi, isCCW: ccw)]
        }

        var result = circle(helixRadius)
        let growth = pole.radius - helixRadius
        guard growth > 1e-6 else {
            return result
        }

        let turns = max(1, Int((growth / stepover).rounded(.up)))
        let stepsPerTurn = 72
        let total = turns * stepsPerTurn
        var previous = CGPoint(x: c.x + helixRadius * cos(startAngle), y: c.y + helixRadius * sin(startAngle))
        for step in 1...total {
            let t = Double(step) / Double(total)
            let radius = helixRadius + growth * t
            let angle = startAngle + sign * 2 * Double.pi * Double(step) / Double(stepsPerTurn)
            let next = CGPoint(x: c.x + radius * cos(angle), y: c.y + radius * sin(angle))
            result.append(.line(start: previous, end: next))
            previous = next
        }
        result.append(contentsOf: circle(pole.radius))
        return result
    }

    // MARK: Fast marching distance

    private struct HeapItem {
        var d: Double
        var v: Int32
    }

    private func propagateDistance(from pole: SCEngine.PocketCenter) {
        for v in 0..<distance.count where !reached[v] {
            distance[v] = .infinity
            known[v] = false
        }
        var heap: [HeapItem] = []

        func push(_ item: HeapItem) {
            heap.append(item)
            var i = heap.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                if heap[parent].d <= heap[i].d { break }
                heap.swapAt(parent, i)
                i = parent
            }
        }
        func pop() -> HeapItem? {
            guard let top = heap.first else { return nil }
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var smallest = i
                    if l < heap.count, heap[l].d < heap[smallest].d { smallest = l }
                    if r < heap.count, heap[r].d < heap[smallest].d { smallest = r }
                    if smallest == i { break }
                    heap.swapAt(i, smallest)
                    i = smallest
                }
            }
            return top
        }

        // Seeds: the free disk is the starting front; its rim is measured exactly.
        let c = pole.point
        var inDisk = Set<Int>()
        for v in 0..<inRegion.count where inRegion[v] && !reached[v] {
            let p = point(v)
            if hypot(p.x - c.x, p.y - c.y) <= pole.radius {
                inDisk.insert(v)
                distance[v] = 0
                known[v] = true
            }
        }
        let offsets = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for v in inDisk {
            let i = v % nx, j = v / nx
            for (di, dj) in offsets {
                let ni = i + di, nj = j + dj
                guard ni >= 0, ni < nx, nj >= 0, nj < ny else { continue }
                let w = index(ni, nj)
                guard inRegion[w], !known[w], !reached[w] else { continue }
                let p = point(w)
                let d = max(hypot(p.x - c.x, p.y - c.y) - pole.radius, 0)
                if d < distance[w] {
                    distance[w] = d
                    push(HeapItem(d: d, v: Int32(w)))
                }
            }
        }

        while let item = pop() {
            let v = Int(item.v)
            if known[v] || item.d > distance[v] { continue }
            known[v] = true
            let i = v % nx, j = v / nx
            for (di, dj) in offsets {
                let ni = i + di, nj = j + dj
                guard ni >= 0, ni < nx, nj >= 0, nj < ny else { continue }
                let w = index(ni, nj)
                guard inRegion[w], !known[w], !reached[w] else { continue }
                let updated = solveEikonal(i: ni, j: nj)
                if updated < distance[w] {
                    distance[w] = updated
                    push(HeapItem(d: updated, v: Int32(w)))
                }
            }
        }
        for v in 0..<known.count where known[v] {
            reached[v] = true
        }
    }

    /// Upwind solution of |grad d| = 1 at vertex (i, j) from its known neighbours.
    private func solveEikonal(i: Int, j: Int) -> Double {
        var a = Double.infinity
        var b = Double.infinity
        if i > 0, known[index(i - 1, j)] { a = min(a, distance[index(i - 1, j)]) }
        if i + 1 < nx, known[index(i + 1, j)] { a = min(a, distance[index(i + 1, j)]) }
        if j > 0, known[index(i, j - 1)] { b = min(b, distance[index(i, j - 1)]) }
        if j + 1 < ny, known[index(i, j + 1)] { b = min(b, distance[index(i, j + 1)]) }
        if a.isInfinite && b.isInfinite { return .infinity }
        if a.isInfinite { return b + h }
        if b.isInfinite { return a + h }
        if abs(a - b) >= h { return min(a, b) + h }
        return (a + b + (2 * h * h - (a - b) * (a - b)).squareRoot()) / 2
    }

    // MARK: Bands and pieces

    /// Splits the field into bands one stepover thick and each band into connected pieces,
    /// and records which piece feeds which.
    private func buildPieces() {
        pieces = []
        var bandOf = [Int32](repeating: -1, count: distance.count)
        var pieceOf = [Int32](repeating: -1, count: distance.count)
        for v in 0..<distance.count where known[v] && !cleared[v] && distance[v] > 0 {
            bandOf[v] = Int32(max(0, Int((distance[v] / stepover - 1e-9).rounded(.up)) - 1))
        }

        let offsets = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for start in 0..<distance.count where bandOf[start] >= 0 && pieceOf[start] < 0 {
            let id = pieces.count
            var piece = Piece(band: Int(bandOf[start]), vertices: [])
            var stack = [start]
            pieceOf[start] = Int32(id)
            while let v = stack.popLast() {
                piece.vertices.append(Int32(v))
                let i = v % nx, j = v / nx
                for (di, dj) in offsets {
                    let ni = i + di, nj = j + dj
                    guard ni >= 0, ni < nx, nj >= 0, nj < ny else { continue }
                    let w = index(ni, nj)
                    if bandOf[w] == bandOf[start], pieceOf[w] < 0 {
                        pieceOf[w] = Int32(id)
                        stack.append(w)
                    }
                }
            }
            pieces.append(piece)
        }

        // Feeding relation: a piece of band k feeds the touching pieces of band k + 1.
        var edges = Set<Int>()
        for p in pieces.indices {
            for raw in pieces[p].vertices {
                let v = Int(raw)
                let i = v % nx, j = v / nx
                for (di, dj) in offsets {
                    let ni = i + di, nj = j + dj
                    guard ni >= 0, ni < nx, nj >= 0, nj < ny else { continue }
                    let q = Int(pieceOf[index(ni, nj)])
                    guard q >= 0, q != p, pieces[q].band == pieces[p].band + 1 else { continue }
                    let key = p * (pieces.count + 1) + q
                    if edges.insert(key).inserted {
                        pieces[p].children.append(q)
                        pieces[q].parentsLeft += 1
                    }
                }
            }
        }
        pieceIndex = pieceOf
    }

    var pieceIndex: [Int32] = []
    var currentPole = SCEngine.PocketCenter(point: .zero, radius: 0)

    private func finish(piece id: Int, ready: inout [Int]) {
        ready.removeAll { $0 == id }
        for raw in pieces[id].vertices {
            cleared[Int(raw)] = true
        }
        for child in pieces[id].children {
            pieces[child].parentsLeft -= 1
            if pieces[child].parentsLeft == 0 {
                ready.append(child)
            }
        }
    }

    /// The piece to cut next: a ready piece that continues the one just finished if there
    /// is one (that is what clears a branch to its tip), otherwise the nearest ready piece.
    private func nextPiece(from position: CGPoint, ready: [Int], after last: Int?) -> Int? {
        func score(_ id: Int) -> Double {
            var best = Double.greatestFiniteMagnitude
            for curve in curves(of: id) {
                if let s = curve.first?.startPoint {
                    best = min(best, hypot(s.x - position.x, s.y - position.y))
                }
            }
            return best
        }
        var candidates = ready
        if let last {
            let continuing = ready.filter { pieces[last].children.contains($0) }
            if !continuing.isEmpty {
                candidates = continuing
            }
        }
        return candidates.min { score($0) < score($1) }
    }

    // MARK: Passes of a piece

    /// The passes that clear a piece: the line of constant distance on its far side, as
    /// directed curves with the cleared side on the left (climb) or the right (conventional).
    private func curves(of id: Int) -> [[SC.Segment]] {
        if let cached = pieces[id].curves {
            return cached
        }
        let level = Double(pieces[id].band + 1) * stepover
        var result: [[SC.Segment]] = []

        for polyline in isoPolylines(of: id, level: level) {
            var points = polyline
            guard points.count >= 2 else { continue }
            let closed = hypot(points[0].x - points[points.count - 1].x, points[0].y - points[points.count - 1].y) < 1e-9

            if !closed {
                if let hit = boundaryHit(from: points[0], towards: unit(points[0], points[1])) {
                    points.insert(hit, at: 0)
                }
                let n = points.count
                if let hit = boundaryHit(from: points[n - 1], towards: unit(points[n - 1], points[n - 2])) {
                    points.append(hit)
                }
            }
            points = simplify(points, tolerance: 0.12 * h)
            if !ccw {
                points.reverse()
            }
            var curve: [SC.Segment] = []
            for k in 0..<(points.count - 1) where hypot(points[k + 1].x - points[k].x, points[k + 1].y - points[k].y) > 1e-9 {
                curve.append(.line(start: points[k], end: points[k + 1]))
            }
            if curve.reduce(0.0, { $0 + $1.pathLength }) > 1.5 * h {
                result.append(curve)
            }
        }
        pieces[id].curves = result
        return result
    }

    private func unit(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
        let d = hypot(to.x - from.x, to.y - from.y)
        guard d > 1e-12 else { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: (from.x - to.x) / d, y: (from.y - to.y) / d)
    }

    /// Where a ray leaving `origin` along `direction` meets the wall or an island zone
    /// within a few cells, if it does.
    private func boundaryHit(from origin: CGPoint, towards direction: CGPoint) -> CGPoint? {
        let reach = 3.5 * h
        let far = CGPoint(x: origin.x + direction.x * reach, y: origin.y + direction.y * reach)
        let ray = SC.Segment.line(start: origin, end: far)
        var best: Double?
        for loop in boundaryLoops {
            for segment in loop {
                for t in engine.intersectionParameters(of: ray, with: segment) where t > 1e-9 && t <= 1 + 1e-9 {
                    if best == nil || t < best! {
                        best = t
                    }
                }
            }
        }
        if let t = best {
            return CGPoint(x: origin.x + direction.x * reach * t, y: origin.y + direction.y * reach * t)
        }
        // No clean hit: snap to the nearest boundary point when it is really close.
        var nearest: CGPoint?
        var nearestDistance = 1.6 * h
        for loop in boundaryLoops {
            if let p = engine.nearestPoint(onLoop: loop, to: origin) {
                let d = hypot(p.x - origin.x, p.y - origin.y)
                if d < nearestDistance {
                    nearestDistance = d
                    nearest = p
                }
            }
        }
        return nearest
    }

    /// Douglas-Peucker.
    private func simplify(_ points: [CGPoint], tolerance: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            var worst = 0.0
            var worstIndex = -1
            let pa = points[a], pb = points[b]
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let len = hypot(dx, dy)
            if b - a < 2 { continue }
            for k in (a + 1)..<b {
                let p = points[k]
                let d: Double
                if len < 1e-12 {
                    d = hypot(p.x - pa.x, p.y - pa.y)
                } else {
                    d = abs((p.x - pa.x) * dy - (p.y - pa.y) * dx) / len
                }
                if d > worst {
                    worst = d
                    worstIndex = k
                }
            }
            if worst > tolerance, worstIndex > 0 {
                keep[worstIndex] = true
                stack.append((a, worstIndex))
                stack.append((worstIndex, b))
            }
        }
        return points.enumerated().filter { keep[$0.offset] }.map { $0.element }
    }

    // MARK: Marching squares

    /// Directed iso-lines of the distance field at `level` inside piece `id`, with lower
    /// distance on the left. Open lines end where the region's edge is; closed ones are
    /// returned with their first point repeated at the end.
    private func isoPolylines(of id: Int, level: Double) -> [[CGPoint]] {
        var next: [Int: Int] = [:]
        var hasIncoming = Set<Int>()
        var positions: [Int: CGPoint] = [:]
        var seenCells = Set<Int>()

        // Key of the edge from vertex (i, j) to (i + 1, j) [vertical = false]
        // or to (i, j + 1) [vertical = true].
        func key(_ i: Int, _ j: Int, _ vertical: Bool) -> Int {
            (index(i, j) << 1) | (vertical ? 1 : 0)
        }
        func crossing(_ i: Int, _ j: Int, _ vertical: Bool) -> Int {
            let k = key(i, j, vertical)
            if positions[k] == nil {
                let a = index(i, j)
                let b = vertical ? index(i, j + 1) : index(i + 1, j)
                let fa = distance[a] - level, fb = distance[b] - level
                let t = fa / (fa - fb)
                let pa = point(a), pb = point(b)
                positions[k] = CGPoint(x: pa.x + (pb.x - pa.x) * t, y: pa.y + (pb.y - pa.y) * t)
            }
            return k
        }

        for raw in pieces[id].vertices {
            let v = Int(raw)
            let vi = v % nx, vj = v / nx
            for ci in (vi - 1)...vi {
                for cj in (vj - 1)...vj {
                    guard ci >= 0, cj >= 0, ci + 1 < nx, cj + 1 < ny else { continue }
                    let cell = index(ci, cj)
                    guard seenCells.insert(cell).inserted else { continue }

                    let v0 = index(ci, cj), v1 = index(ci + 1, cj)
                    let v2 = index(ci + 1, cj + 1), v3 = index(ci, cj + 1)
                    guard known[v0], known[v1], known[v2], known[v3],
                          inRegion[v0], inRegion[v1], inRegion[v2], inRegion[v3] else { continue }
                    let f0 = distance[v0] - level, f1 = distance[v1] - level
                    let f2 = distance[v2] - level, f3 = distance[v3] - level
                    var mask = 0
                    if f0 < 0 { mask |= 1 }
                    if f1 < 0 { mask |= 2 }
                    if f2 < 0 { mask |= 4 }
                    if f3 < 0 { mask |= 8 }
                    if mask == 0 || mask == 15 { continue }

                    // Edges: 0 bottom, 1 right, 2 top, 3 left.
                    func edge(_ e: Int) -> Int {
                        switch e {
                            case 0: return crossing(ci, cj, false)
                            case 1: return crossing(ci + 1, cj, true)
                            case 2: return crossing(ci, cj + 1, false)
                            default: return crossing(ci, cj, true)
                        }
                    }
                    var pairs: [(Int, Int)] = []
                    let centreInside = (f0 + f1 + f2 + f3) / 4 < 0
                    switch mask {
                        case 1: pairs = [(0, 3)]
                        case 2: pairs = [(1, 0)]
                        case 3: pairs = [(1, 3)]
                        case 4: pairs = [(2, 1)]
                        case 5: pairs = centreInside ? [(0, 1), (2, 3)] : [(0, 3), (2, 1)]
                        case 6: pairs = [(2, 0)]
                        case 7: pairs = [(2, 3)]
                        case 8: pairs = [(3, 2)]
                        case 9: pairs = [(0, 2)]
                        case 10: pairs = centreInside ? [(3, 0), (1, 2)] : [(1, 0), (3, 2)]
                        case 11: pairs = [(1, 2)]
                        case 12: pairs = [(3, 1)]
                        case 13: pairs = [(0, 1)]
                        default: pairs = [(3, 0)] // 14
                    }
                    for (from, to) in pairs {
                        let a = edge(from), b = edge(to)
                        next[a] = b
                        hasIncoming.insert(b)
                    }
                }
            }
        }

        var lines: [[CGPoint]] = []
        var visited = Set<Int>()

        // Open lines start at an edge nothing leads into.
        for start in next.keys.sorted() where !hasIncoming.contains(start) {
            var line: [CGPoint] = []
            var k = start
            while !visited.contains(k) {
                visited.insert(k)
                line.append(positions[k]!)
                guard let following = next[k] else {
                    break
                }
                k = following
                if next[k] == nil {
                    line.append(positions[k]!)
                    visited.insert(k)
                    break
                }
            }
            lines.append(line)
        }
        // What is left are closed loops.
        for start in next.keys.sorted() where !visited.contains(start) {
            var line: [CGPoint] = []
            var k = start
            while !visited.contains(k) {
                visited.insert(k)
                line.append(positions[k]!)
                guard let following = next[k] else { break }
                k = following
            }
            if line.count > 2 {
                line.append(line[0])
                lines.append(line)
            }
        }
        return lines
    }

    // MARK: Links

    private struct MinHeap {
        var items: [(f: Double, v: Int32)] = []
        mutating func push(_ f: Double, _ v: Int32) {
            items.append((f, v))
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                if items[parent].f <= items[i].f { break }
                items.swapAt(parent, i)
                i = parent
            }
        }
        mutating func pop() -> (f: Double, v: Int32)? {
            guard let top = items.first else { return nil }
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var smallest = i
                    if l < items.count, items[l].f < items[smallest].f { smallest = l }
                    if r < items.count, items[r].f < items[smallest].f { smallest = r }
                    if smallest == i { break }
                    items.swapAt(i, smallest)
                    i = smallest
                }
            }
            return top
        }
    }

    private var searchStamp: [Int32] = []
    private var searchCost: [Double] = []
    private var searchParent: [Int32] = []
    private var searchGeneration: Int32 = 0

    private func isPassable(_ v: Int, allowed: Int?) -> Bool {
        guard inRegion[v] else { return false }
        if cleared[v] { return true }
        if let allowed, pieceIndex.count > v, Int(pieceIndex[v]) == allowed { return true }
        return false
    }

    /// A way from `a` to `b` over ground that is already cleared (or about to be, as piece
    /// `allowed`): the shortest route on the grid, pulled straight wherever a direct move
    /// is safe. Used when a straight link isn't, e.g. to go round an island or across the
    /// cleared middle from one branch to the next. `nil` when there is no route, or it is
    /// so much longer than lifting the tool would be that lifting is the better choice.
    private func routeThroughCleared(from a: CGPoint, to b: CGPoint, allowed: Int?) -> [SC.Segment]? {
        func nearestPassable(_ p: CGPoint) -> Int? {
            let i0 = Int(((p.x - x0) / h).rounded()), j0 = Int(((p.y - y0) / h).rounded())
            var best: (v: Int, d: Double)?
            for di in -3...3 {
                for dj in -3...3 {
                    let i = i0 + di, j = j0 + dj
                    guard i >= 0, i < nx, j >= 0, j < ny else { continue }
                    let v = index(i, j)
                    guard isPassable(v, allowed: allowed) else { continue }
                    let q = point(v)
                    let d: Double = hypot(q.x - p.x, q.y - p.y)
                    if best == nil || d < best!.d { best = (v: v, d: d) }
                }
            }
            return best?.v
        }
        guard let source = nearestPassable(a), let target = nearestPassable(b) else {
            return nil
        }
        if searchStamp.count != inRegion.count {
            searchStamp = Array(repeating: 0, count: inRegion.count)
            searchCost = Array(repeating: 0, count: inRegion.count)
            searchParent = Array(repeating: -1, count: inRegion.count)
        }
        searchGeneration += 1
        let generation = searchGeneration
        let goal = point(target)
        func heuristic(_ v: Int) -> Double {
            let p = point(v)
            return hypot(p.x - goal.x, p.y - goal.y)
        }

        var heap = MinHeap()
        searchStamp[source] = generation
        searchCost[source] = 0
        searchParent[source] = -1
        heap.push(heuristic(source), Int32(source))
        var closed = Set<Int>()
        var found = false
        var expanded = 0
        let neighbours = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]

        while let (_, raw) = heap.pop() {
            let v = Int(raw)
            if closed.contains(v) { continue }
            closed.insert(v)
            if v == target { found = true; break }
            expanded += 1
            if expanded > 120_000 { break }
            let i = v % nx, j = v / nx
            for (di, dj) in neighbours {
                let ni = i + di, nj = j + dj
                guard ni >= 0, ni < nx, nj >= 0, nj < ny else { continue }
                let w = index(ni, nj)
                guard isPassable(w, allowed: allowed) else { continue }
                if di != 0, dj != 0 {
                    // No cutting across the corner of something that isn't passable.
                    guard isPassable(index(i + di, j), allowed: allowed), isPassable(index(i, j + dj), allowed: allowed) else { continue }
                }
                let cost = searchCost[v] + (di != 0 && dj != 0 ? h * 2.0.squareRoot() : h)
                if searchStamp[w] != generation || cost < searchCost[w] {
                    searchStamp[w] = generation
                    searchCost[w] = cost
                    searchParent[w] = Int32(v)
                    heap.push(cost + heuristic(w), Int32(w))
                }
            }
        }
        guard found else { return nil }

        var cells: [Int] = []
        var v = target
        while v >= 0 {
            cells.append(v)
            v = Int(searchParent[v])
        }
        cells.reverse()
        var points = [a] + cells.map { point($0) } + [b]

        // Pull the route straight: from each point jump to the farthest one it can see.
        var route: [CGPoint] = [points[0]]
        var i = 0
        while i < points.count - 1 {
            var j = points.count - 1
            while j > i + 1, !linkIsSafe(from: points[i], to: points[j], allowed: allowed) {
                j -= 1
            }
            route.append(points[j])
            i = j
        }
        points = route

        var length = 0.0
        var segments: [SC.Segment] = []
        for k in 0..<(points.count - 1) {
            let d = hypot(points[k + 1].x - points[k].x, points[k + 1].y - points[k].y)
            if d > 1e-9 {
                segments.append(.line(start: points[k], end: points[k + 1]))
                length += d
            }
        }
        let direct = hypot(b.x - a.x, b.y - a.y)
        // Beyond this, a lift and a plunge is cheaper than dragging the tool around.
        guard length <= 6 * direct + 12 * stepover else { return nil }
        return segments
    }

    /// True when the tool can go straight from `a` to `b` without leaving the region or
    /// cutting into material that has not been cleared (or is about to be, as piece `allowed`).
    private func linkIsSafe(from a: CGPoint, to b: CGPoint, allowed: Int?) -> Bool {
        let length = hypot(b.x - a.x, b.y - a.y)
        if length < 1e-9 { return true }

        let chord = SC.Segment.line(start: a, end: b)
        for loop in boundaryLoops {
            for segment in loop {
                for t in engine.intersectionParameters(of: chord, with: segment) where t > 1e-4 && t < 1 - 1e-4 {
                    return false
                }
            }
        }
        let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        guard engine.clearance(at: middle, wallRing: wallRing, zones: zones) > -1e-6 else {
            return false
        }

        // Every sample must sit on cleared ground (any of the four surrounding grid points will do).
        let steps = max(2, Int((length / (0.7 * h)).rounded(.up)))
        // The two ends sit on the wall, outside the grid's reach: only the stretch between is checked.
        for k in 1..<max(steps, 2) {
            let t = Double(k) / Double(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            let fi = (p.x - x0) / h, fj = (p.y - y0) / h
            let i0 = Int(fi.rounded(.down)), j0 = Int(fj.rounded(.down))
            var ok = false
            var any = false
            for di in -1...2 {
                for dj in -1...2 {
                    let i = i0 + di, j = j0 + dj
                    guard i >= 0, i < nx, j >= 0, j < ny else { continue }
                    let v = index(i, j)
                    guard inRegion[v] else { continue }
                    any = true
                    if cleared[v] { ok = true }
                    if let allowed, pieceIndex.count > v, Int(pieceIndex[v]) == allowed { ok = true }
                    if known[v], distance[v] <= 0 { ok = true }
                }
            }
            if any, !ok {
                return false
            }
        }
        return true
    }
}
