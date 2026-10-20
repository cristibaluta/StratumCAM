import Testing
import Foundation
import simd
@testable import StratumCAM

struct HelixSmallHole_Tests {
    @Test func helixStaysInsideHole() throws {
        let contour = SC.Contour(entities: [
            .init(geometry: .circle(center: SIMD2<Double>(0, 0), radius: 2), reversed: false)
        ], isClosed: true)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 1.0, stepoverPercentage: 0.25),
                                          safeZ: 5, targetDepth: -3)
        let paths = try SCEngine().generateToolpaths(from: [contour], tool: SC.ToolParams(diameter: 3.175), settings: settings,
                                                     operation: .pocket(direction: .climb, pattern: .concentric(direction: .insideOut), entry: .helix(rampAngleDegrees: 3)))
        for p in paths {
            for pass in p.passes {
                print("[helix-hole] pass \(pass.passIndex): first \(pass.waypoints.first!.position) last3 \(pass.waypoints.suffix(3).map { "\($0.position.z)" })")
            }
        }
        let maxR = paths.flatMap { $0.passes.flatMap { $0.waypoints } }.map { hypot($0.position.x, $0.position.y) }.max() ?? 0
        #expect(maxR + 1.5875 <= 2.0 + 1e-6)
    }
}
