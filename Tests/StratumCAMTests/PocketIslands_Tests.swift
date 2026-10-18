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
        #expect(throws: SC.Error.self) { try generate(contour, entry: .ramp(angleDegrees: 3)) }
    }

    @Test("An island too close to the wall, or overlapping another, is rejected")
    func testInvalidIslandsRejected() throws {
        #expect(throws: SC.Error.self) { try generate(pocket(islands: [island(x: 5, y: 12, radius: 2)])) }
        #expect(throws: SC.Error.self) {
            try generate(pocket(islands: [island(x: 20, y: 12, radius: 2), island(x: 25, y: 12, radius: 2)]))
        }
    }
}
