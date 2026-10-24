//
//  ToolSweep.swift
//  StratumCAM
//
//  Test helper: replays a toolpath on a raster of the pocket and reports what the cutter
//  did to the material -- how much of the pocket it reached, whether it ever touched
//  material outside the pocket, and how much of its circumference was cutting.
//

import Foundation
@testable import StratumCAM

struct ToolSweep {

    let cell: Double
    let minX: Double
    let minY: Double
    let nx: Int
    let ny: Int
    let isPocket: [Bool]
    var cut: [Bool]
    let toolRadius: Double

    /// Engagement (degrees of the cutter's circumference in uncut pocket material) at every
    /// sample of the replay.
    private(set) var engagement: [Double] = []

    private(set) var gouged = 0
    private let distanceToWall: (Double, Double) -> Double

    /// - Parameters:
    ///   - inside: whether a point is inside the pocket (material to remove).
    ///   - distanceToWall: distance from a point to the pocket's outline.
    init(bounds: (minX: Double, maxX: Double, minY: Double, maxY: Double),
         toolRadius: Double,
         cell: Double = 0.15,
         inside: (Double, Double) -> Bool,
         distanceToWall: @escaping (Double, Double) -> Double) {
        self.cell = cell
        self.toolRadius = toolRadius
        self.minX = bounds.minX - toolRadius - 1
        self.minY = bounds.minY - toolRadius - 1
        self.nx = Int((bounds.maxX - bounds.minX + 2 * toolRadius + 2) / cell) + 1
        self.ny = Int((bounds.maxY - bounds.minY + 2 * toolRadius + 2) / cell) + 1
        self.distanceToWall = distanceToWall
        var pocket = [Bool](repeating: false, count: nx * ny)
        for j in 0..<ny {
            for i in 0..<nx {
                pocket[j * nx + i] = inside(bounds.minX - toolRadius - 1 + Double(i) * cell, bounds.minY - toolRadius - 1 + Double(j) * cell)
            }
        }
        self.isPocket = pocket
        self.cut = [Bool](repeating: false, count: nx * ny)
    }

    /// Replays the moves that cut at the final depth (z equal to the lowest z in the path).
    mutating func replay(_ waypoints: [SC.Waypoint]) {
        let floor = waypoints.map { Double($0.position.z) }.min() ?? 0
        var previous: SC.Waypoint?
        for waypoint in waypoints {
            defer { previous = waypoint }
            guard let from = previous,
                  abs(Double(waypoint.position.z) - floor) < 1e-9,
                  abs(Double(from.position.z) - floor) < 1e-9 else {
                continue
            }
            let a = CGPoint(x: Double(from.position.x), y: Double(from.position.y))
            let b = CGPoint(x: Double(waypoint.position.x), y: Double(waypoint.position.y))
            switch waypoint.motion {
                case .rapid:
                    continue
                case .linear:
                    sampleLine(a, b)
                case .arcCW(let c):
                    sampleArc(a, b, center: c, ccw: false)
                case .arcCCW(let c):
                    sampleArc(a, b, center: c, ccw: true)
            }
        }
    }

    private mutating func sampleLine(_ a: CGPoint, _ b: CGPoint) {
        let length = hypot(b.x - a.x, b.y - a.y)
        let steps = max(1, Int((length / (cell * 1.5)).rounded(.up)))
        for k in 0...steps {
            let t = Double(k) / Double(steps)
            stamp(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
        }
    }

    private mutating func sampleArc(_ a: CGPoint, _ b: CGPoint, center: CGPoint, ccw: Bool) {
        let r = hypot(a.x - center.x, a.y - center.y)
        let a0 = atan2(a.y - center.y, a.x - center.x)
        var sweep = SC.Segment.sweepAngle(start: a0, end: atan2(b.y - center.y, b.x - center.x), isCCW: ccw)
        if sweep < 1e-9, hypot(a.x - b.x, a.y - b.y) < 1e-9 { sweep = 2 * .pi }
        let steps = max(2, Int((r * sweep / (cell * 1.5)).rounded(.up)))
        for k in 0...steps {
            let angle = a0 + (ccw ? 1.0 : -1.0) * sweep * Double(k) / Double(steps)
            stamp(center.x + r * cos(angle), center.y + r * sin(angle))
        }
    }

    private mutating func stamp(_ x: Double, _ y: Double) {
        let ci = Int(((x - minX) / cell).rounded())
        let cj = Int(((y - minY) / cell).rounded())

        // Engagement: how much of the circumference sits in material that is still uncut.
        var uncut = 0
        let probes = 72
        for k in 0..<probes {
            let angle = 2 * Double.pi * Double(k) / Double(probes)
            let i = ci + Int((0.97 * toolRadius * cos(angle) / cell).rounded())
            let j = cj + Int((0.97 * toolRadius * sin(angle) / cell).rounded())
            if i >= 0, i < nx, j >= 0, j < ny, isPocket[j * nx + i], !cut[j * nx + i] {
                uncut += 1
            }
        }
        engagement.append(360 * Double(uncut) / Double(probes))

        let reach = Int((toolRadius / cell).rounded(.up))
        for dj in -reach...reach {
            for di in -reach...reach {
                let i = ci + di, j = cj + dj
                guard i >= 0, i < nx, j >= 0, j < ny else { continue }
                if Double(di * di + dj * dj) * cell * cell <= toolRadius * toolRadius {
                    let index = j * nx + i
                    if !cut[index] {
                        cut[index] = true
                        if !isPocket[index] {
                            let px = minX + Double(i) * cell, py = minY + Double(j) * cell
                            // Touching the wall itself isn't gouging it: allow a little slack.
                            if distanceToWall(px, py) > cell * 0.8 {
                                gouged += 1
                            }
                        }
                    }
                }
            }
        }
    }

    /// Fraction of the pocket's area the cutter reached.
    var coverage: Double {
        var total = 0, reached = 0
        for index in isPocket.indices where isPocket[index] {
            total += 1
            if cut[index] { reached += 1 }
        }
        return total == 0 ? 0 : Double(reached) / Double(total)
    }

    func engagementPercentile(_ p: Double) -> Double {
        let sorted = engagement.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))]
    }
}

/// Even-odd point-in-polygon and distance to a polygon outline.
struct PolygonShape {
    let points: [(Double, Double)]

    func contains(_ x: Double, _ y: Double) -> Bool {
        var inside = false
        var j = points.count - 1
        for i in 0..<points.count {
            let (xi, yi) = points[i], (xj, yj) = points[j]
            if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    func distanceToOutline(_ x: Double, _ y: Double) -> Double {
        var best = Double.infinity
        var j = points.count - 1
        for i in 0..<points.count {
            let (ax, ay) = points[j], (bx, by) = points[i]
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(max(((x - ax) * dx + (y - ay) * dy) / len2, 0), 1) : 0
            best = min(best, hypot(x - (ax + t * dx), y - (ay + t * dy)))
            j = i
        }
        return best
    }

    var bounds: (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        (points.map { $0.0 }.min()!, points.map { $0.0 }.max()!, points.map { $0.1 }.min()!, points.map { $0.1 }.max()!)
    }
}
