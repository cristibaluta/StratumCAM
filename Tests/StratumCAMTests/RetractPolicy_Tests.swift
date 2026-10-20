import Testing
import Foundation
import simd
@testable import StratumCAM

struct RetractPolicy_Tests {

    private func rect() -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2(0, 0), b: SIMD2(40, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2(40, 0), b: SIMD2(40, 24)), reversed: false),
            .init(geometry: .line(a: SIMD2(40, 24), b: SIMD2(0, 24)), reversed: false),
            .init(geometry: .line(a: SIMD2(0, 24), b: SIMD2(0, 0)), reversed: false)
        ], isClosed: true)
    }

    private func passes(_ policy: SC.RetractPolicy, entry: SC.EntryStrategy) throws -> [SC.ToolpathPass] {
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 1.0, stepoverPercentage: 0.4),
                                          safeZ: 5, retractZ: 1, targetDepth: -3, retractPolicy: policy)
        let paths = try SCEngine().generateToolpaths(from: [rect()], tool: SC.ToolParams(diameter: 6), settings: settings,
                                                     operation: .pocket(direction: .climb, pattern: .concentric(direction: .insideOut), entry: entry))
        return try #require(paths.first).passes
    }

    @Test func safeZIsDefaultAndRetractsEveryLayer() throws {
        let p = try passes(.safeZ, entry: .plunge)
        #expect(p.count == 3)
        for pass in p {
            #expect(pass.waypoints.first?.position.z == 5)
            #expect(pass.waypoints.last?.position.z == 5)
        }
    }

    @Test func clearanceLiftsOnlyRetractZBetweenLayers() throws {
        let p = try passes(.clearance, entry: .plunge)
        #expect(p[0].waypoints.last?.position.z == 0.0)
        #expect(p[1].waypoints.first?.position.z == 0.0)
        #expect(p[1].waypoints.last?.position.z == -1.0)
        #expect(p[2].waypoints.first?.position.z == -1.0)
        #expect(p[2].waypoints.last?.position.z == 5) // last layer fully retracts
    }

    @Test func noneStaysAtDepthBetweenLayers() throws {
        let p = try passes(.none, entry: .helix(rampAngleDegrees: 3))
        #expect(p[0].waypoints.last?.position.z == -1)
        #expect(p[1].waypoints.first?.position.z == -1)
        #expect(p[2].waypoints.last?.position.z == 5)
    }
}
