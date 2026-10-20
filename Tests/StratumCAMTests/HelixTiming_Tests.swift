import Testing
import Foundation
import simd
@testable import StratumCAM

struct HelixTiming_Tests {

    private func time(_ label: String, _ block: () throws -> Void) rethrows {
        let start = Date()
        try block()
        print("[helix-timing] \(label): \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    @Test func circleHelix() throws {
        let contour = SC.Contour(entities: [
            .init(geometry: .circle(center: SIMD2<Double>(0, 0), radius: 20), reversed: false)
        ], isClosed: true)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 1.0, stepoverPercentage: 0.25),
                                          safeZ: 5, targetDepth: -2)
        try time("circle helix") {
            _ = try SCEngine().generateToolpaths(from: [contour], tool: SC.ToolParams(diameter: 6), settings: settings,
                                                 operation: .pocket(direction: .climb, pattern: .concentric(direction: .insideOut), entry: .helix(rampAngleDegrees: 3)))
        }
    }

    @Test func rectangleHelixMultiPass() throws {
        let contour = SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2(0, 0), b: SIMD2(20, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2(20, 0), b: SIMD2(20, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2(20, 10), b: SIMD2(0, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2(0, 10), b: SIMD2(0, 0)), reversed: false)
        ], isClosed: true)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 1.0),
                                          safeZ: 5, targetDepth: -2)
        try time("rect helix multipass") {
            _ = try SCEngine().generateToolpaths(from: [contour], tool: SC.ToolParams(diameter: 6), settings: settings,
                                                 operation: .pocket(direction: .climb, pattern: .offset, entry: .helix(rampAngleDegrees: 30)))
        }
    }
}

struct HelixSmallHole_Tests {
    @Test func helixStaysInsideHole() throws {
        let contour = SC.Contour(entities: [
            .init(geometry: .circle(center: SIMD2<Double>(0, 0), radius: 2), reversed: false)
        ], isClosed: true)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 1.0, stepoverPercentage: 0.25),
                                          safeZ: 5, targetDepth: -3)
        let paths = try SCEngine().generateToolpaths(from: [contour], tool: SC.ToolParams(diameter: 3.175), settings: settings,
                                                     operation: .pocket(direction: .climb, pattern: .concentric(direction: .insideOut), entry: .helix(rampAngleDegrees: 3)))
        let maxR = paths.flatMap { $0.passes.flatMap { $0.waypoints } }.map { hypot($0.position.x, $0.position.y) }.max() ?? 0
        print("[helix-hole] max tool-centre radius \(maxR), edge reach \(maxR + 1.5875)")
        #expect(maxR + 1.5875 <= 2.0 + 1e-6)
    }
}
