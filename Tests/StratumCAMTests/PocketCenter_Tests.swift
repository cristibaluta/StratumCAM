//
//  PocketCenter_Tests.swift
//  StratumCAM
//

import Testing
import CoreGraphics
import simd
@testable import StratumCAM

struct PocketCenter_Tests {

    // MARK: - Helpers

    private func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> SC.Segment {
        .line(start: CGPoint(x: x0, y: y0), end: CGPoint(x: x1, y: y1))
    }

    private func polygon(_ points: [(Double, Double)]) -> [SC.Segment] {
        points.indices.map { i in
            let a = points[i], b = points[(i + 1) % points.count]
            return line(a.0, a.1, b.0, b.1)
        }
    }

    /// Counter-clockwise circle zone, as `islandZones` would hand it over (the engine only
    /// needs the loop, not its winding, for the clearance maths).
    private func circleZone(x: Double, y: Double, radius: Double) -> SCEngine.PocketIslandZone {
        SCEngine.PocketIslandZone(loop: [
            .arc(center: CGPoint(x: x, y: y), radius: radius, startAngle: -.pi / 2, endAngle: .pi / 2, isCCW: false),
            .arc(center: CGPoint(x: x, y: y), radius: radius, startAngle: .pi / 2, endAngle: 3 * .pi / 2, isCCW: false)
        ])
    }

    private func lShapeContour(islands: [SC.Contour] = []) -> SC.Contour {
        let pts: [(Double, Double)] = [(0, 0), (40, 0), (40, 16), (16, 16), (16, 40), (0, 40)]
        let entities = pts.indices.map { i -> SC.Contour.Chained in
            let a = pts[i], b = pts[(i + 1) % pts.count]
            return .init(geometry: .line(a: SIMD2<Double>(a.0, a.1), b: SIMD2<Double>(b.0, b.1)), reversed: false)
        }
        return SC.Contour(entities: entities, isClosed: true, islands: islands)
    }

    private func circleIsland(x: Double, y: Double, radius: Double) -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .circle(center: SIMD2<Double>(x, y), radius: radius), reversed: false)
        ], isClosed: true)
    }

    private func waypoints(_ contour: SC.Contour) throws -> [SC.Waypoint] {
        let tool = SC.ToolParams(diameter: 4.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)
        return try SCEngine().generateToolpaths(
            from: [contour],
            tool: tool,
            settings: settings,
            operation: .pocket(direction: .climb, pattern: .concentric(direction: .insideOut), entry: .plunge)
        )[0].passes[0].waypoints
    }

    /// Inside the L's tool-centre region (the wall offset by the tool radius 2).
    private func insideLWall(_ p: SIMD3<Double>, tolerance: Double = 1e-6) -> Bool {
        let x = Double(p.x), y = Double(p.y)
        let lower = x >= 2 - tolerance && x <= 38 + tolerance && y >= 2 - tolerance && y <= 14 + tolerance
        let left = x >= 2 - tolerance && x <= 14 + tolerance && y >= 2 - tolerance && y <= 38 + tolerance
        return lower || left
    }

    // MARK: - Pole of inaccessibility

    @Test("A circle's centre is the furthest point, at the circle's radius")
    func testCircleCentre() throws {
        let wall = [
            SC.Segment.arc(center: CGPoint(x: 5, y: -3), radius: 10, startAngle: -.pi / 2, endAngle: .pi / 2, isCCW: true),
            SC.Segment.arc(center: CGPoint(x: 5, y: -3), radius: 10, startAngle: .pi / 2, endAngle: 3 * .pi / 2, isCCW: true)
        ]
        let center = try #require(SCEngine().pocketCenter(wallRing: wall, zones: []))
        #expect(abs(Double(center.point.x) - 5) < 1e-6 && abs(Double(center.point.y) + 3) < 1e-6)
        #expect(abs(center.radius - 10) < 1e-6)
    }

    @Test("An L shape's centre sits at the junction of its arms, not in an arm")
    func testLShapeCentre() throws {
        // Arms are 12 wide; the largest circle is pushed into the corner by the reflex vertex.
        let wall = polygon([(2, 2), (38, 2), (38, 14), (14, 14), (14, 38), (2, 38)])
        let center = try #require(SCEngine().pocketCenter(wallRing: wall, zones: []))
        #expect(center.radius > 6.9 && center.radius < 7.2, "radius \(center.radius)")
        #expect(center.point.x < 14 && center.point.y < 14, "centre \(center.point) should be at the junction")
    }

    @Test("The centre accounts for islands: nothing in the pocket has more clearance")
    func testCentreAvoidsIslands() throws {
        let wall = polygon([(2, 2), (38, 2), (38, 22), (2, 22)])
        let zones = [circleZone(x: 20, y: 12, radius: 4)]
        let engine = SCEngine()
        let center = try #require(engine.pocketCenter(wallRing: wall, zones: zones))

        // The circle fits between the island and the left (or right) wall.
        #expect(center.radius > 6.9, "radius \(center.radius)")
        // Its radius is the exact clearance of its centre, so it touches but never crosses.
        let clearance = engine.clearance(at: center.point, wallRing: wall, zones: zones)
        #expect(abs(clearance - center.radius) < 1e-9)
        #expect(hypot(Double(center.point.x) - 20, Double(center.point.y) - 12) >= 4 + center.radius - 1e-9)

        // Brute force: no point of a fine grid beats it by more than the search precision.
        var x = 2.0
        while x <= 38 {
            var y = 2.0
            while y <= 22 {
                let c = engine.clearance(at: CGPoint(x: x, y: y), wallRing: wall, zones: zones)
                #expect(c <= center.radius + 5e-3, "(\(x), \(y)) has clearance \(c) > \(center.radius)")
                y += 0.25
            }
            x += 0.25
        }
    }

    // MARK: - Toolpath

    @Test("An irregular pocket starts with a small circle at its centre and stays inside the wall")
    func testIrregularPocketStartsAtCentre() throws {
        let w = try waypoints(lShapeContour())

        // w[0] is the rapid above the start, w[1] the plunge: both at the bottom of the
        // innermost circle, which is around the junction of the arms (~9, ~9).
        #expect(w[1].position.x < 14 && w[1].position.y < 14, "started at \(w[1].position)")
        #expect(abs(Double(w[1].position.x) - 9) < 2.5 && abs(Double(w[1].position.y) - 9) < 4.5)

        // The first moves are arcs.
        switch w[2].motion {
            case .arcCCW, .arcCW: break
            default: Issue.record("first cutting move should be an arc, got \(w[2].motion)")
        }

        for waypoint in w where waypoint.position.z < 0 {
            #expect(insideLWall(waypoint.position), "\(waypoint.position) leaves the wall offset")
        }
    }

    @Test("An irregular pocket with an island starts away from the island and keeps clear of it")
    func testIrregularPocketWithIsland() throws {
        // Island radius 2 + tool radius 2 = keep-out radius 4, inside the upper arm.
        let w = try waypoints(lShapeContour(islands: [circleIsland(x: 8, y: 28, radius: 2)]))

        #expect(w[1].position.x < 20 && w[1].position.y < 20, "started at \(w[1].position)")

        for waypoint in w where waypoint.position.z < 0 {
            #expect(hypot(Double(waypoint.position.x) - 8, Double(waypoint.position.y) - 28) >= 4 - 1e-6,
                    "\(waypoint.position) is inside the island's keep-out zone")
            #expect(insideLWall(waypoint.position), "\(waypoint.position) leaves the wall offset")
        }
    }
}
