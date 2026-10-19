//
//  PocketIslands_Tests.swift
//  StratumCAM
//

import Testing
import CoreGraphics
import simd
@testable import StratumCAM

struct PocketIslands_Tests {

    private func pocket(islands: [SC.Contour]) -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(40, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(40, 0), b: SIMD2<Double>(40, 24)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(40, 24), b: SIMD2<Double>(0, 24)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, 24), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true, islands: islands)
    }

    private func island(x: Double, y: Double, radius: Double) -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .circle(center: SIMD2<Double>(x, y), radius: radius), reversed: false)
        ], isClosed: true)
    }

    private func generate(_ contour: SC.Contour,
                          pattern: SC.PocketClearingPattern = .concentric(direction: .insideOut),
                          entry: SC.EntryStrategy = .plunge) throws -> [SC.Waypoint] {
        let tool = SC.ToolParams(diameter: 4.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)
        return try SCEngine().generateToolpaths(
            from: [contour],
            tool: tool,
            settings: settings,
            operation: .pocket(direction: .climb, pattern: pattern, entry: entry)
        )[0].passes[0].waypoints
    }

    @Test("Toolpath never enters an island's keep-out zone")
    func testToolStaysOutOfIslands() throws {
        // Island radius 2 + tool radius 2 = zone radius 4.
        let islands = [island(x: 28, y: 12, radius: 2), island(x: 12, y: 15, radius: 2)]
        let waypoints = try generate(pocket(islands: islands))

        for w in waypoints {
            for isl in [(28.0, 12.0), (12.0, 15.0)] {
                let distance = hypot(Double(w.position.x) - isl.0, Double(w.position.y) - isl.1)
                #expect(distance >= 4.0 - 1e-6, "Test Failed: waypoint \(w.position) is inside an island's keep-out zone")
            }
        }
        // The island walls are cut: some waypoint sits exactly on the zone edge.
        #expect(waypoints.contains { abs(hypot(Double($0.position.x) - 28, Double($0.position.y) - 12) - 4.0) < 1e-6 })
    }

    @Test("Islands change the toolpath compared with the same pocket without them")
    func testIslandsChangeToolpath() throws {
        let plain = try generate(pocket(islands: []))
        let withIsland = try generate(pocket(islands: [island(x: 28, y: 12, radius: 2)]))
        #expect(plain != withIsland)
    }

    @Test("Islands are refused by other patterns and by non-plunge entries")
    func testIslandsRejected() throws {
        let contour = pocket(islands: [island(x: 28, y: 12, radius: 2)])
        #expect(throws: SC.Error.self) { try generate(contour, pattern: .offset) }
        #expect(throws: SC.Error.self) { try generate(contour, entry: .helix(rampAngleDegrees: 3)) }
    }

    @Test("Ramp entry is supported with islands, descends along the path and stays out of zones")
    func testRampEntryWithIslands() throws {
        let w = try generate(pocket(islands: [island(x: 28, y: 12, radius: 2)]), entry: .ramp(angleDegrees: 3))
        // Safe-Z rapid, rapid to top of stock, then a descent: never a straight plunge to depth.
        #expect(w[0].position.z == 5.0)
        #expect(w[1].position.z == 0.0)
        #expect(w[2].position.z < 0.0 && w[2].position.z > -1.0)
        #expect(w.contains { $0.position.z == -1.0 })
        for p in w where p.motion != .rapid {
            let d = hypot(p.position.x - 28, p.position.y - 12)
            #expect(d >= 4.0 - 1e-6)
        }
    }

    @Test("An island too close to the wall, or overlapping another, is rejected")
    func testInvalidIslandsRejected() throws {
        #expect(throws: SC.Error.self) { try generate(pocket(islands: [island(x: 5, y: 12, radius: 2)])) }
        #expect(throws: SC.Error.self) {
            try generate(pocket(islands: [island(x: 20, y: 12, radius: 2), island(x: 25, y: 12, radius: 2)]))
        }
    }

    // MARK: - Automatic island detection

    private func generateAll(_ contours: [SC.Contour],
                             pattern: SC.PocketClearingPattern = .concentric(direction: .insideOut)) throws -> [SC.OutputToolpath] {
        let tool = SC.ToolParams(diameter: 4.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)
        return try SCEngine().generateToolpaths(
            from: contours,
            tool: tool,
            settings: settings,
            operation: .pocket(direction: .climb, pattern: pattern, entry: .plunge)
        )
    }

    private func rectangle(x: Double, y: Double, width: Double, height: Double) -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(x, y), b: SIMD2<Double>(x + width, y)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(x + width, y), b: SIMD2<Double>(x + width, y + height)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(x + width, y + height), b: SIMD2<Double>(x, y + height)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(x, y + height), b: SIMD2<Double>(x, y)), reversed: false)
        ], isClosed: true)
    }

    @Test("Shapes nested in a flat contour list become islands without setting `islands`")
    func testAutoDetectedIslandsMatchManualOnes() throws {
        let islands = [island(x: 28, y: 12, radius: 2), island(x: 12, y: 15, radius: 2)]

        let manual = try generateAll([pocket(islands: islands)])
        let automatic = try generateAll([pocket(islands: [])] + islands)

        // The islands are consumed, not machined as pockets of their own.
        #expect(automatic.count == 1)
        #expect(automatic[0].passes[0].waypoints == manual[0].passes[0].waypoints)
    }

    @Test("Detection does not depend on the order of the input list")
    func testAutoDetectionIgnoresOrder() throws {
        let islands = [island(x: 28, y: 12, radius: 2), island(x: 12, y: 15, radius: 2)]
        let forward = try generateAll([pocket(islands: [])] + islands)
        let islandsFirst = try generateAll(islands + [pocket(islands: [])])
        #expect(forward.count == 1)
        #expect(islandsFirst.count == 1)
        #expect(forward[0].passes[0].waypoints == islandsFirst[0].passes[0].waypoints)
    }

    @Test("Separate pockets each get only the islands inside them")
    func testIslandsAssignedToTheirOwnPocket() throws {
        let left = rectangle(x: 0, y: 0, width: 40, height: 24)
        let right = rectangle(x: 60, y: 0, width: 40, height: 24)
        let rightIsland = island(x: 88, y: 12, radius: 2)

        let toolpaths = try generateAll([left, right, rightIsland])
        #expect(toolpaths.count == 2)

        let leftPoints = toolpaths[0].passes[0].waypoints
        let rightPoints = toolpaths[1].passes[0].waypoints
        let leftPlain = try generateAll([left])[0].passes[0].waypoints
        let rightPlain = try generateAll([right])[0].passes[0].waypoints

        #expect(leftPoints == leftPlain)       // the left pocket has no island
        #expect(rightPoints != rightPlain)     // the right one does
    }

    @Test("A shape inside an island is a pocket of its own")
    func testNestingAlternates() {
        let outer = rectangle(x: 0, y: 0, width: 100, height: 100)
        let island = rectangle(x: 20, y: 20, width: 60, height: 60)
        let inner = rectangle(x: 40, y: 40, width: 20, height: 20)

        let resolved = SCEngine().resolvePocketIslands([outer, island, inner])
        #expect(resolved.count == 2)
        #expect(resolved[0].islands.count == 1)   // outer keeps `island`
        #expect(resolved[1].islands.isEmpty)      // `inner` is its own pocket
    }

    @Test("Overlapping, non-nested shapes stay independent pockets")
    func testCrossingShapesAreNotNested() {
        let a = rectangle(x: 0, y: 0, width: 40, height: 24)
        let b = rectangle(x: 30, y: 10, width: 40, height: 24)
        let resolved = SCEngine().resolvePocketIslands([a, b])
        #expect(resolved.count == 2)
        #expect(resolved.allSatisfy { $0.islands.isEmpty })
    }

    @Test("Open contours are passed through and still rejected")
    func testOpenContourPassesThrough() {
        var open = rectangle(x: 10, y: 10, width: 5, height: 5)
        open.isClosed = false
        let resolved = SCEngine().resolvePocketIslands([pocket(islands: []), open])
        #expect(resolved.count == 2)
        #expect(resolved[0].islands.isEmpty)
    }

    @Test("Detected islands are refused by patterns that don't support them")
    func testAutoDetectedIslandsRejectedByOtherPatterns() {
        let contours = [pocket(islands: []), island(x: 28, y: 12, radius: 2)]
        #expect(throws: SC.Error.self) { try generateAll(contours, pattern: .offset) }
    }
}
