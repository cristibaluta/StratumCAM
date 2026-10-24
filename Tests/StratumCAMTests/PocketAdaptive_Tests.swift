//
//  PocketAdaptive_Tests.swift
//  StratumCAM
//
//  The two shapes below are the DXF files used to compare against Fusion 360's adaptive
//  clearing: a five-pointed star (clear the middle first, then every arm in turn) and a
//  130 x 35 rectangle with islands, one of them a semicircle pushed into a corner.
//

import Testing
import Foundation
import CoreGraphics
@testable import StratumCAM

struct PocketAdaptive_Tests {

    // MARK: Fixtures

    static let starPoints: [(Double, Double)] = [
        (23.73518913841543, 43.00668907540511), (16.780127231112573, 30.108565764940664),
        (4.000000059604645, 37.000000551342964), (11.976910964284432, 21.16988675201899),
        (2.735188825491144, 7.0066885389634965), (20.735189093711952, 13.006688628370426),
        (34.00000050663948, 2.0000000298023224), (32.00000047683716, 18.0000002682209),
        (45.33499643368561, 30.47381788899007), (28.735189212921206, 30.00668888169008)
    ]

    static func starGeometry() -> [SC.Geometry] {
        [.polyline(vertices: starPoints.map { SC.Geometry.Vertex(SIMD2<Double>($0.0, $0.1)) }, closed: true)]
    }

    static func rectangleWithIslandsGeometry() -> [SC.Geometry] {
        func v(_ x: Double, _ y: Double) -> SC.Geometry.Vertex { SC.Geometry.Vertex(SIMD2<Double>(x, y)) }
        return [
            .polyline(vertices: [v(0, 0), v(130, 0), v(130, 35), v(0, 35)], closed: true),
            .circle(center: SIMD2(85.0, 25.0), radius: 3.755299845886528),
            .circle(center: SIMD2(99.78639935583031, 12.47927062556613), radius: 4.69276341596225),
            // Stands on the bottom wall.
            .polyline(vertices: [v(54.58373358463825, 15.342106124408286), v(70, 15.342106124408286),
                                 v(70, 0), v(54.58373358463825, 0)], closed: true),
            // Open: a semicircle whose ends land on the right and bottom walls.
            .arc(center: SIMD2(125, 5), radius: 8.143868613693423, startDeg: 52.123694486149844, endDeg: 217.8763055138502)
        ]
    }

    static let tool = SC.ToolParams(diameter: 3.0)

    func generate(_ geometry: [SC.Geometry],
                  direction: SC.CutDirection = .climb,
                  entry: SC.EntryStrategy = .helix(rampAngleDegrees: 3),
                  load: Double = 1.2,
                  depth: Double = -0.5) throws -> [SC.OutputToolpath] {
        let cutting = SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5, targetDepth: depth)
        return try SCEngine().generateToolpaths(
            from: EntityChainer.chain(geometry),
            tool: Self.tool,
            settings: settings,
            operation: .pocket(direction: direction,
                               pattern: .adaptive(settings: SC.AdaptiveSettings(optimalLoad: load)),
                               entry: entry))
    }

    func starSweep(_ waypoints: [SC.Waypoint]) -> ToolSweep {
        let star = PolygonShape(points: Self.starPoints)
        var sweep = ToolSweep(bounds: star.bounds,
                              toolRadius: 1.5,
                              inside: { star.contains($0, $1) },
                              distanceToWall: { star.distanceToOutline($0, $1) })
        sweep.replay(waypoints)
        return sweep
    }

    // MARK: Star

    @Test("Star: the cutter never leaves the pocket and reaches (nearly) all of it")
    func testStarIsClearedWithoutGouging() throws {
        let toolpaths = try generate(Self.starGeometry())
        #expect(toolpaths.count == 1)
        let sweep = starSweep(toolpaths[0].passes[0].waypoints)
        #expect(sweep.gouged == 0)
        // Only the very tips, where the tool does not fit, stay uncut.
        #expect(sweep.coverage > 0.97, "coverage \(sweep.coverage)")
    }

    @Test("Star: starts with a helix in the middle, then clears each arm completely in turn")
    func testStarArmsAreClearedOneAtATime() throws {
        let toolpaths = try generate(Self.starGeometry())
        let waypoints = toolpaths[0].passes[0].waypoints

        // Comes down in a helix: the first moves after the rapids descend gradually.
        let descent = waypoints.prefix(40).filter { $0.motion != .rapid && $0.position.z < 0 && $0.position.z > -0.5 }
        #expect(!descent.isEmpty, "expected a helix descent")

        // Which arm is a point in? Nearest of the five tips, by direction from the centre.
        let centre = (22.7, 22.5)
        let tips = stride(from: 0, to: 10, by: 2).map { Self.starPoints[$0] }
        func arm(_ w: SC.Waypoint) -> Int? {
            let x = Double(w.position.x) - centre.0, y = Double(w.position.y) - centre.1
            guard hypot(x, y) > 11 else { return nil } // the middle disk belongs to no arm
            let angle = atan2(y, x)
            return tips.indices.min { a, b in
                angularGap(angle, atan2(tips[a].1 - centre.1, tips[a].0 - centre.0))
                    < angularGap(angle, atan2(tips[b].1 - centre.1, tips[b].0 - centre.0))
            }
        }
        // Walk the cut in order and note each arm as it is entered. The final wall pass
        // revisits every arm, so only the stretch up to the fifth distinct arm counts.
        let cutting = waypoints.filter { $0.motion != .rapid && abs(Double($0.position.z) + 0.5) < 1e-9 }
        var visits: [Int] = []
        for w in cutting {
            if let a = arm(w), visits.last != a { visits.append(a) }
            if Set(visits).count == 5 { break }
        }
        // Each arm is entered exactly once before the next: with the wavefront taking one
        // bite of each arm in turn the same arm would come back again and again.
        #expect(Set(visits).count == 5, "arm sequence \(visits)")
        #expect(visits.count == 5, "arm sequence \(visits)")
    }

    private func angularGap(_ a: Double, _ b: Double) -> Double {
        var d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d = 2 * .pi - d }
        return d
    }

    @Test("Star: radial engagement stays near the target instead of spiking in the arms")
    func testStarEngagementIsControlled() throws {
        let toolpaths = try generate(Self.starGeometry())
        let sweep = starSweep(toolpaths[0].passes[0].waypoints)
        // Target load 1.2 mm of a 3 mm tool is 78 degrees on a straight cut; the path is
        // allowed some excess in tight spots but nothing close to slotting (180 degrees).
        #expect(sweep.engagementPercentile(0.95) <= 100, "p95 engagement \(sweep.engagementPercentile(0.95))")
        #expect(sweep.engagementPercentile(0.99) <= 140, "p99 engagement \(sweep.engagementPercentile(0.99))")
    }

    @Test("Smaller optimal load makes more, lighter passes")
    func testOptimalLoadChangesPassSpacing() throws {
        let coarse = try generate(Self.starGeometry(), load: 1.5)[0].passes[0].waypoints.count
        let fine = try generate(Self.starGeometry(), load: 0.8)[0].passes[0].waypoints.count
        #expect(fine > coarse)
    }

    @Test("Conventional direction reverses the way round")
    func testConventionalDirection() throws {
        let climb = try generate(Self.starGeometry(), direction: .climb)[0].passes[0].waypoints
        let conventional = try generate(Self.starGeometry(), direction: .conventional)[0].passes[0].waypoints
        func firstArc(_ list: [SC.Waypoint]) -> Bool? {
            for w in list {
                if case .arcCCW = w.motion { return true }
                if case .arcCW = w.motion { return false }
            }
            return nil
        }
        #expect(firstArc(climb) == true)
        #expect(firstArc(conventional) == false)
    }

    @Test("Plunge and ramp entries work, and each Z pass repeats the path")
    func testEntriesAndZPasses() throws {
        for entry: SC.EntryStrategy in [.plunge, .ramp(angleDegrees: 3), .helix(rampAngleDegrees: 3)] {
            let toolpaths = try generate(Self.starGeometry(), entry: entry, depth: -2.0)
            #expect(toolpaths[0].passes.count == 2)
            for pass in toolpaths[0].passes {
                #expect(pass.waypoints.contains { abs(Double($0.position.z) - pass.depthZ) < 1e-9 })
                #expect(pass.waypoints.last?.position.z == 5.0)
            }
        }
    }

    // MARK: Rectangle with islands

    func rectangleSweep(_ waypoints: [SC.Waypoint]) -> ToolSweep {
        // Pocket = rectangle minus the two circles, the block and the corner semicircle.
        func inside(_ x: Double, _ y: Double) -> Bool {
            guard x >= 0, x <= 130, y >= 0, y <= 35 else { return false }
            if hypot(x - 85, y - 25) < 3.755299845886528 { return false }
            if hypot(x - 99.78639935583031, y - 12.47927062556613) < 4.69276341596225 { return false }
            if x > 54.58373358463825, x < 70, y < 15.342106124408286 { return false }
            if hypot(x - 125, y - 5) < 8.143868613693423 { return false }
            return true
        }
        func wallDistance(_ x: Double, _ y: Double) -> Double {
            var d = Double.infinity
            d = min(d, abs(hypot(x - 85, y - 25) - 3.755299845886528))
            d = min(d, abs(hypot(x - 99.78639935583031, y - 12.47927062556613) - 4.69276341596225))
            d = min(d, abs(hypot(x - 125, y - 5) - 8.143868613693423))
            d = min(d, abs(x - 54.58373358463825) + (y < 15.342106124408286 ? 0 : 1e3), abs(x - 70) + (y < 15.342106124408286 ? 0 : 1e3))
            d = min(d, abs(y - 15.342106124408286) + ((x > 54.58 && x < 70) ? 0 : 1e3))
            d = min(d, abs(x), abs(x - 130), abs(y), abs(y - 35))
            return d
        }
        var sweep = ToolSweep(bounds: (0, 130, 0, 35), toolRadius: 1.5, cell: 0.2, inside: inside, distanceToWall: wallDistance)
        sweep.replay(waypoints)
        return sweep
    }

    @Test("Rectangle with islands: an open outline on the wall and a block on the wall are islands too")
    func testRectangleWithIslands() throws {
        let toolpaths = try generate(Self.rectangleWithIslandsGeometry())
        #expect(toolpaths.count == 1, "the open arc and the touching block must not become pockets of their own")
        let sweep = rectangleSweep(toolpaths[0].passes[0].waypoints)
        #expect(sweep.gouged == 0)
        #expect(sweep.coverage > 0.99, "coverage \(sweep.coverage)")
    }

    @Test("Rectangle with islands: starts in the biggest free area and clears it before moving on")
    func testRectangleStartsAtLargestFreeArea() throws {
        let waypoints = try generate(Self.rectangleWithIslandsGeometry())[0].passes[0].waypoints
        let start = waypoints.first { $0.motion != .rapid }!
        // The biggest empty circle is at the left end of the pocket, nowhere near the islands.
        #expect(Double(start.position.x) < 35)
        #expect(Double(start.position.y) > 8 && Double(start.position.y) < 27)
    }

    @Test("Rectangle with islands: engagement stays controlled around the islands")
    func testRectangleEngagement() throws {
        let sweep = rectangleSweep(try generate(Self.rectangleWithIslandsGeometry())[0].passes[0].waypoints)
        #expect(sweep.engagementPercentile(0.95) <= 110, "p95 \(sweep.engagementPercentile(0.95))")
    }
}
