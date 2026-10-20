//
//  SCEngine+PocketCenter.swift
//  StratumCAM
//
//  Where a concentric pocket starts. For an irregular shape (with or without islands) the
//  plain inward offset rings collapse into a thin sliver, or around an island, instead of
//  into a centre. The fix is to find the point of the cuttable area that is furthest from
//  every wall and island (the "pole of inaccessibility"), grow true circles from there until
//  the biggest one touches something, and only then fall back to the offset rings.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// The point of the tool-centre region that is furthest from the wall and from every
    /// island zone, and how far that is: the largest circle the tool centre can travel
    /// around without touching anything.
    struct PocketCenter {
        let point: CGPoint
        let radius: Double
    }

    // MARK: - Pole of inaccessibility

    /// Finds the largest empty circle inside `wallRing` that stays clear of every zone.
    ///
    /// `wallRing` is the pocket wall already offset by the tool radius and the zones are the
    /// islands already offset by it too, so the region between them is exactly where the tool
    /// centre may be. Uses the quadtree "polylabel" search: the clearance (signed distance to
    /// the nearest wall or zone edge, negative outside the region) is 1-Lipschitz, so a square
    /// cell of half-size `h` can't hold a point better than `clearance(centre) + h * sqrt(2)`.
    /// Cells that can't beat the best point by more than `precision` are discarded, the most
    /// promising cell is split first. The result is within `precision` of the true maximum, and
    /// `radius` is the exact clearance of the returned `point`, so a circle of that radius
    /// never crosses anything.
    ///
    /// Returns `nil` when no point of the region has any clearance.
    func pocketCenter(wallRing: [SC.Segment], zones: [PocketIslandZone], precision: Double? = nil) -> PocketCenter? {
        let box = wallRing.boundingBox
        let width = box.maxX - box.minX
        let height = box.maxY - box.minY
        guard width.isFinite, height.isFinite, width > 1e-9, height > 1e-9 else {
            return nil
        }
        let tolerance = precision ?? max(1e-4, min(width, height) * 1e-4)

        struct Cell {
            let x: Double
            let y: Double
            let half: Double
            let clearance: Double
            var potential: Double { clearance + half * 2.0.squareRoot() }
        }

        func makeCell(_ x: Double, _ y: Double, _ half: Double) -> Cell {
            Cell(x: x, y: y, half: half, clearance: clearance(at: CGPoint(x: x, y: y), wallRing: wallRing, zones: zones))
        }

        // Cover the bounding box with square cells; the shorter side sets the cell size.
        let cellSize = min(width, height)
        let half = cellSize / 2
        var cells: [Cell] = []
        var x = box.minX
        while x < box.maxX {
            var y = box.minY
            while y < box.maxY {
                cells.append(makeCell(x + half, y + half, half))
                y += cellSize
            }
            x += cellSize
        }

        // The bounding box centre is a good first guess (and the exact answer for a circle).
        var best = makeCell((box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2, 0)
        for cell in cells where cell.clearance > best.clearance {
            best = cell
        }

        // Max-heap on `potential`: popping the most promising cell is O(log n) instead of
        // scanning (and shifting) the whole queue for every cell.
        var heap: [Cell] = []
        func push(_ cell: Cell) {
            heap.append(cell)
            var i = heap.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                if heap[parent].potential >= heap[i].potential { break }
                heap.swapAt(parent, i)
                i = parent
            }
        }
        func pop() -> Cell? {
            guard let top = heap.first else { return nil }
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var largest = i
                    if l < heap.count, heap[l].potential > heap[largest].potential { largest = l }
                    if r < heap.count, heap[r].potential > heap[largest].potential { largest = r }
                    if largest == i { break }
                    heap.swapAt(i, largest)
                    i = largest
                }
            }
            return top
        }
        cells.forEach(push)

        let maxCells = 20_000
        var processed = 0
        while processed < maxCells, let cell = pop() {
            processed += 1

            if cell.clearance > best.clearance {
                best = cell
            }
            // Best-first: nothing left in the queue can do better than this cell's bound.
            if cell.potential - best.clearance <= tolerance {
                break
            }

            let quarter = cell.half / 2
            for (dx, dy) in [(-quarter, -quarter), (quarter, -quarter), (-quarter, quarter), (quarter, quarter)] {
                let child = makeCell(cell.x + dx, cell.y + dy, quarter)
                if child.clearance > best.clearance {
                    best = child
                }
                if child.potential - best.clearance > tolerance {
                    push(child)
                }
            }
        }
        OffsetTiming.log("[pocketCenter] processed \(processed) cells")

        guard best.clearance > 1e-6 else {
            return nil
        }
        return PocketCenter(point: CGPoint(x: best.x, y: best.y), radius: best.clearance)
    }

    /// Signed distance from `point` to the edge of the tool-centre region: positive inside
    /// `wallRing` and outside every zone, negative otherwise.
    func clearance(at point: CGPoint, wallRing: [SC.Segment], zones: [PocketIslandZone]) -> Double {
        var nearest = distance(from: point, toLoop: wallRing)
        var inside = isInsideLoop(point, loop: wallRing)
        for zone in zones {
            nearest = min(nearest, distance(from: point, toLoop: zone.loop))
            if inside, isInsideLoop(point, loop: zone.loop) {
                inside = false
            }
        }
        return inside ? nearest : -nearest
    }

    // MARK: - Circles from the centre

    /// Inside-out ring stack for an irregular pocket: perfect circles around the pocket's
    /// centre, growing one `stepover` at a time until the biggest touches the wall or an
    /// island, then the same circles keep growing but moulded onto the wall (see
    /// `grownRings`), ending with the wall ring itself.
    ///
    /// - Parameters:
    ///   - offsetRings: `pocketRings`' output, outside-in; only its first ring, the wall
    ///     ring, is used.
    ///   - zones: island keep-out zones (empty for a pocket without islands).
    /// - Returns: the rings inside-out, or `nil` when there is no usable centre, or, for a
    ///   pocket without islands, when a link between two rings would leave the pocket. The
    ///   caller then keeps its plain reversed offset rings.
    func centeredRings(offsetRings: [[SC.Segment]],
                       zones: [PocketIslandZone],
                       toolRadius: Double,
                       stepover: Double) -> [[SC.Segment]]? {

        guard let wallRing = offsetRings.first, stepover > 1e-6,
              let center = pocketCenter(wallRing: wallRing, zones: zones),
              center.radius > 1e-3 else {
            return nil
        }

        let counterClockwise = OffsetTools.isCCWWinding(wallRing)

        // 1. Circles, smallest first: the helix-radius circle, then one stepover bigger each
        //    time, the last (shorter step) being exactly the circle that touches the wall or
        //    an island. The smallest circle is within the tool radius, so it reaches the centre.
        let radii = insideOutCircleRadii(maxRadius: center.radius, toolRadius: toolRadius, stepover: stepover)
        var stack: [[SC.Segment]] = radii.map {
            circleRing(center: center.point, radius: $0, counterClockwise: counterClockwise)
        }

        // 2. Keep growing from the last circle. Where the circle is still free it keeps being a
        //    circle; where it has reached the wall it follows the wall. The last ring is the
        //    wall itself.
        guard let grown = grownRings(center: center,
                                     wallRing: wallRing,
                                     stepover: stepover,
                                     counterClockwise: counterClockwise) else {
            return nil
        }

        var previousStart = stack.last?.first?.startPoint
        for ring in grown {
            // Start each ring at the point nearest the previous one so the link is short.
            var next = ring
            if let previousStart, let nearest = nearestPoint(onLoop: ring, to: previousStart) {
                next = rotatedLoop(ring, startingAt: nearest)
            }

            if zones.isEmpty, let previousStart, let start = next.first?.startPoint,
               !linkStaysInside(from: previousStart, to: start, wallRing: wallRing) {
                return nil
            }
            stack.append(next)
            previousStart = next.first?.startPoint
        }

        return stack
    }

    // MARK: - Circles moulding onto the wall

    /// The rings that follow the biggest free circle: for each radius `center.radius + k * stepover`
    /// the outline of "the disk of that radius around the centre, limited to the pocket". Free
    /// parts of the outline are circle arcs, parts that have hit the wall run along it, so the
    /// circle gradually takes the shape of the pocket. The last ring is the wall ring itself
    /// (omitted when the biggest circle already is the wall, as in a round pocket).
    /// Returns `nil` when an outline can't be assembled into closed loops.
    private func grownRings(center: PocketCenter,
                            wallRing: [SC.Segment],
                            stepover: Double,
                            counterClockwise: Bool) -> [[SC.Segment]]? {

        let farthest = wallRing.map { farthestDistance(from: center.point, on: $0) }.max() ?? 0
        var rings: [[SC.Segment]] = []

        var radius = center.radius + stepover
        var count = 0
        // A ring that would differ from the wall only by a sliver at the far tip is skipped.
        while radius < farthest - 0.25 * stepover, count < 500 {
            guard let loops = grownLoops(radius: radius,
                                         center: center.point,
                                         wallRing: wallRing,
                                         counterClockwise: counterClockwise) else {
                return nil
            }
            rings.append(contentsOf: loops)
            radius += stepover
            count += 1
        }

        if farthest > center.radius + max(1e-4, center.radius * 1e-4) {
            rings.append(wallRing)
        }
        return rings
    }

    /// The boundary of (disk of `radius` around `center`) intersected with the pocket, as
    /// closed loops. The circle and the wall ring share a winding, so the pieces of each that
    /// survive join end to start.
    private func grownLoops(radius: Double,
                            center: CGPoint,
                            wallRing: [SC.Segment],
                            counterClockwise: Bool) -> [[SC.Segment]]? {

        let circle = circleRing(center: center, radius: radius, counterClockwise: counterClockwise)

        // Parts of the circle inside the pocket.
        var pieces: [SC.Segment] = []
        for arc in circle {
            let cuts = wallRing.flatMap { intersectionParameters(of: arc, with: $0) }
            for piece in split(arc, atParameters: cuts) where isInsideLoop(midpoint(of: piece), loop: wallRing) {
                pieces.append(piece)
            }
        }
        // Parts of the wall inside the circle.
        for segment in wallRing {
            let cuts = circle.flatMap { intersectionParameters(of: segment, with: $0) }
            for piece in split(segment, atParameters: cuts) {
                let middle = midpoint(of: piece)
                if hypot(middle.x - center.x, middle.y - center.y) < radius - 1e-9 {
                    pieces.append(piece)
                }
            }
        }
        var pool = pieces.filter { !$0.isDegenerate }
        guard !pool.isEmpty else {
            return []
        }

        let tolerance = 1e-5
        var loops: [[SC.Segment]] = []
        while !pool.isEmpty {
            var loop = [pool.removeFirst()]
            let origin = loop[0].startPoint
            while true {
                let end = loop[loop.count - 1].endPoint
                if hypot(end.x - origin.x, end.y - origin.y) < tolerance {
                    break
                }
                guard let next = pool.firstIndex(where: {
                    hypot($0.startPoint.x - end.x, $0.startPoint.y - end.y) < tolerance
                }) else {
                    return nil
                }
                loop.append(pool.remove(at: next))
            }
            loops.append(loop)
        }
        return loops
    }

    /// True when the straight link `from -> to` stays inside the closed `wallRing`
    /// (touching it is fine).
    func linkStaysInside(from: CGPoint, to: CGPoint, wallRing: [SC.Segment]) -> Bool {
        let samples = 16
        for k in 0...samples {
            let t = Double(k) / Double(samples)
            let point = CGPoint(x: from.x + t * (to.x - from.x), y: from.y + t * (to.y - from.y))
            guard isInsideLoop(point, loop: wallRing) || distance(from: point, toLoop: wallRing) < 1e-6 else {
                return false
            }
        }
        return true
    }

    // MARK: - Helix placement

    /// Where a helix entry that starts at `start` (on the edge of the tool-centre `region`)
    /// can spiral without leaving the region: the circle's centre is moved inward from
    /// `start` just far enough that the whole circle, `radius` out in every direction, stays
    /// inside. The radius is capped at 97% of the biggest circle the region can hold, so a
    /// narrow pocket still gets a valid (smaller) helix, with some room to spare.
    ///
    /// The centre is the closest such point to `start`, found by scanning rays out of `start`
    /// and refining where each first reaches enough clearance. Returns `nil` when `region`
    /// has no usable clearance.
    func fittedHelix(start: CGPoint,
                     region: [SC.Segment],
                     desiredRadius: Double) -> (center: CGPoint, radius: Double)? {

        var clock = OffsetTiming.now()
        defer { OffsetTiming.log("[helix] fittedHelix total: \(OffsetTiming.lap(&clock)) ms") }
        guard !region.isEmpty, desiredRadius > 1e-6,
              let pole = pocketCenter(wallRing: region, zones: []), pole.radius > 1e-6 else {
            return nil
        }
        let radius = min(desiredRadius, 0.97 * pole.radius)
        OffsetTiming.log("[helix] pocketCenter: \(OffsetTiming.lap(&clock)) ms")

        func room(_ p: CGPoint) -> Double {
            clearance(at: p, wallRing: region, zones: [])
        }

        // `start` itself already has the room (it can't normally, it sits on the edge).
        if room(start) >= radius {
            return (start, radius)
        }

        // The pole has at least `radius` of clearance, so a hit is always within reach of it.
        let reach = hypot(pole.point.x - start.x, pole.point.y - start.y) + 1e-6
        let rays = 144
        let steps = 96

        var best: (center: CGPoint, distance: Double)?
        for k in 0..<rays {
            let angle = 2 * Double.pi * Double(k) / Double(rays)
            let u = CGPoint(x: cos(angle), y: sin(angle))
            func point(_ t: Double) -> CGPoint {
                CGPoint(x: start.x + u.x * t, y: start.y + u.y * t)
            }

            var previous = 0.0
            for s in 1...steps {
                let t = reach * Double(s) / Double(steps)
                if room(point(t)) >= radius {
                    // Bisect between the last miss and this hit.
                    var lo = previous, hi = t
                    for _ in 0..<40 {
                        let mid = (lo + hi) / 2
                        if room(point(mid)) >= radius { hi = mid } else { lo = mid }
                    }
                    if best == nil || hi < best!.distance {
                        best = (point(hi), hi)
                    }
                    break
                }
                previous = t
            }
        }
        guard let best else {
            return nil
        }
        return (best.center, radius)
    }

    // MARK: - Helpers

    /// Radii of the concentric circles of an inside-out pocket, smallest first.
    ///
    /// Built outward, not inward from the wall: the first circle has the helix radius
    /// (95% of the tool radius, so even a plunge entry has the cutter edge sweep across the
    /// centre, and a helix entry hands off with no jump), each next one is one `stepover`
    /// bigger, and the last is exactly `maxRadius` -- it gets the leftover, shorter step so
    /// it never crosses the boundary. A leftover under a tenth of a stepover is folded into
    /// the previous step instead of producing a sliver ring.
    func insideOutCircleRadii(maxRadius: Double, toolRadius: Double, stepover: Double) -> [Double] {
        let first = min(RampTools.helixRadius(forToolRadius: toolRadius), maxRadius)
        var radii = [first]
        guard stepover > 1e-6 else {
            return radii
        }

        var radius = first + stepover
        while radius < maxRadius - 1e-6 {
            radii.append(radius)
            radius += stepover
        }
        if maxRadius - radii[radii.count - 1] > 1e-6 {
            if radii.count > 1, maxRadius - radii[radii.count - 1] < 0.1 * stepover {
                radii.removeLast()
            }
            radii.append(maxRadius)
        }
        return radii
    }

    /// A full circle as two half-arcs starting at the bottom, so the links between circles
    /// are short vertical moves.
    private func circleRing(center c: CGPoint, radius r: Double, counterClockwise: Bool) -> [SC.Segment] {
        let ccw: [SC.Segment] = [
            .arc(center: c, radius: r, startAngle: -.pi / 2, endAngle: .pi / 2, isCCW: true),
            .arc(center: c, radius: r, startAngle: .pi / 2, endAngle: 3 * .pi / 2, isCCW: true)
        ]
        return counterClockwise ? ccw : ccw.reversed().map { $0.reversed }
    }

    /// The largest distance from `point` to any point of `segment`.
    private func farthestDistance(from point: CGPoint, on segment: SC.Segment) -> Double {
        let start = segment.startPoint, end = segment.endPoint
        var result = max(hypot(start.x - point.x, start.y - point.y), hypot(end.x - point.x, end.y - point.y))

        if case .arc(let center, let radius, let startAngle, let endAngle, let isCCW) = segment {
            let d = hypot(center.x - point.x, center.y - point.y)
            if d < 1e-12 {
                result = max(result, radius)
            } else {
                // The farthest point of a circle is on the line from `point` through its centre.
                let away = atan2(center.y - point.y, center.x - point.x)
                if EngineTools.angleWithinSweep(away, start: startAngle, end: endAngle, isCCW: isCCW) {
                    result = max(result, d + radius)
                }
            }
        }
        return result
    }

    /// The point of the closed `loop` that is nearest to `point`.
    private func nearestPoint(onLoop loop: [SC.Segment], to point: CGPoint) -> CGPoint? {
        var best: (point: CGPoint, distance: Double)?
        for segment in loop {
            let candidate = closestPoint(on: segment, to: point)
            let d: Double = hypot(candidate.x - point.x, candidate.y - point.y)
            if best == nil || d < best!.distance {
                best = (candidate, d)
            }
        }
        return best?.point
    }

    private func closestPoint(on segment: SC.Segment, to point: CGPoint) -> CGPoint {
        switch segment {
            case .line(let a, let b):
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                let t = len2 > 1e-18 ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / len2, 0), 1) : 0
                return CGPoint(x: a.x + t * dx, y: a.y + t * dy)

            case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                let angle: Double = atan2(point.y - center.y, point.x - center.x)
                if EngineTools.angleWithinSweep(angle, start: startAngle, end: endAngle, isCCW: isCCW) {
                    return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                }
                let s = segment.startPoint, e = segment.endPoint
                return hypot(point.x - s.x, point.y - s.y) <= hypot(point.x - e.x, point.y - e.y) ? s : e
        }
    }
}
