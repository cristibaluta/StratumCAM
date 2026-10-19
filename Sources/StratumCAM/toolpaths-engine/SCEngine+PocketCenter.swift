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
        var queue: [Cell] = []
        var x = box.minX
        while x < box.maxX {
            var y = box.minY
            while y < box.maxY {
                queue.append(makeCell(x + half, y + half, half))
                y += cellSize
            }
            x += cellSize
        }

        // The bounding box centre is a good first guess (and the exact answer for a circle).
        var best = makeCell((box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2, 0)
        for cell in queue where cell.clearance > best.clearance {
            best = cell
        }

        let maxCells = 20_000
        var processed = 0
        while processed < maxCells, let index = queue.indices.max(by: { queue[$0].potential < queue[$1].potential }) {
            let cell = queue.remove(at: index)
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
                    queue.append(child)
                }
            }
        }

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
    /// island, followed by the wall offset rings that still reach material the circles don't.
    ///
    /// - Parameters:
    ///   - offsetRings: the plain inward offset rings of the wall, outside-in, `pocketRings`'
    ///     output. Rings lying entirely inside the biggest circle are dropped.
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

        // 1. Circles, smallest first. Spaced exactly one stepover apart counting inwards from
        //    the biggest one, which is the circle that just touches the wall or an island.
        var radii: [Double] = []
        var radius = center.radius
        while radius > 1e-6 {
            radii.append(radius)
            radius -= stepover
        }
        // The smallest circle must reach the centre, or an uncut core is left standing.
        if let innermost = radii.last, innermost > toolRadius {
            radii.append(innermost / 2)
        }
        var stack: [[SC.Segment]] = radii.reversed().map {
            circleRing(center: center.point, radius: $0, counterClockwise: counterClockwise)
        }

        // 2. Offset rings, deepest first. Whatever lies inside the biggest circle is already
        //    cleared (the tool footprint of a point inside the circle is inside the circle
        //    grown by the tool radius), so those rings are skipped.
        let covered = center.radius + max(1e-4, center.radius * 1e-4)
        var previousStart = stack.last?.first?.startPoint
        for ring in offsetRings.reversed() {
            let farthest = ring.map { farthestDistance(from: center.point, on: $0) }.max() ?? 0
            guard farthest > covered else {
                continue
            }
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

    // MARK: - Helpers

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
