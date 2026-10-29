//
//  RestMachining_Tests.swift
//  StratumCAM
//

import Testing
import CoreGraphics
import simd
@testable import StratumCAM

struct RestMachining_Tests {

    private func square(_ size: Double) -> SC.Contour {
        let p = [(0.0, 0.0), (size, 0.0), (size, size), (0.0, size)]
        let entities = p.indices.map { i -> SC.Contour.Chained in
            let a = p[i], b = p[(i + 1) % p.count]
            return .init(geometry: .line(a: SIMD2<Double>(a.0, a.1), b: SIMD2<Double>(b.0, b.1)), reversed: false)
        }
        return SC.Contour(entities: entities, isClosed: true)
    }

    private let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                     plungeRate: 300.0,
                                                                     stepdown: 1.0,
                                                                     stepoverPercentage: 0.4),
                                              safeZ: 5.0,
                                              targetDepth: -1.0)

    @Test func squarePocketRestPassCoversAllFourCornersWithinTheirPockets() throws {
        let engine = SCEngine()
        let big = SC.ToolParams(diameter: 6.0)
        let small = SC.ToolParams(diameter: 2.0)
        let operation = SC.MachiningOperation.pocket(direction: .climb, pattern: .offset, entry: .plunge)

        let pocket = try engine.generateToolpaths(from: [square(20)], tool: big, settings: settings, operation: operation)
        let corners = try #require(pocket.first).restCorners
        #expect(corners.count == 4)

        let rest = try engine.generateToolpaths_rest(corners: corners, tool: small)
        #expect(rest.count == 4)

        for output in rest {
            #expect(!output.passes.isEmpty)
            for pass in output.passes {
                for waypoint in pass.waypoints where waypoint.motion != .rapid {
                    // The small tool's centre stays inside the 20x20 pocket, a radius from the walls.
                    #expect(waypoint.position.x >= 1 - 1e-6 && waypoint.position.x <= 19 + 1e-6)
                    #expect(waypoint.position.y >= 1 - 1e-6 && waypoint.position.y <= 19 + 1e-6)
                }
            }
        }
    }

    @Test func restPassSweepsFromTheWallEndsInToTheCorner() throws {
        let engine = SCEngine()
        let big = SC.ToolParams(diameter: 6.0)
        let operation = SC.MachiningOperation.pocket(direction: .climb, pattern: .offset, entry: .plunge)
        let pocket = try engine.generateToolpaths(from: [square(20)], tool: big, settings: settings, operation: operation)
        let allCorners = pocket.first?.restCorners ?? []
        guard let corner = allCorners.first(where: { $0.corner == CGPoint(x: 0, y: 0) }),
              let sweep = engine.restSweep(for: corner, smallRadius: 1.0, stepover: 0.8),
              let firstSegment = sweep.first,
              case .line(_, let last) = sweep[sweep.count - 1] else {
            Issue.record("no corner or sweep")
            return
        }
        let first = firstSegment.startPoint

        // Ends at the single point where the small tool touches both walls, (1, 1).
        #expect(abs(last.x - 1) < 1e-6 && abs(last.y - 1) < 1e-6)
        // Starts at the wall ends, a wall's tangent distance (3) and more away from the corner.
        #expect(first.x + first.y > 2)
        #expect(hypot(first.x - 1, first.y - 1) > 2)
    }

    @Test func toolNotSmallerThanTheBigOneIsRejected() throws {
        let engine = SCEngine()
        let big = SC.ToolParams(diameter: 6.0)
        let operation = SC.MachiningOperation.pocket(direction: .climb, pattern: .offset, entry: .plunge)
        let pocket = try engine.generateToolpaths(from: [square(20)], tool: big, settings: settings, operation: operation)
        let corners = try #require(pocket.first).restCorners

        #expect(throws: SC.Error.toolIncompatible) {
            try engine.generateRestToolpaths(corners: corners, tool: SC.ToolParams(diameter: 6.0), settings: settings)
        }
    }

    @Test func noCornersGivesNothing() throws {
        let rest = try SCEngine().generateRestToolpaths(corners: [], tool: SC.ToolParams(diameter: 2.0), settings: settings)
        #expect(rest.isEmpty)
    }
}

private extension SCEngine {
    func generateToolpaths_rest(corners: [SC.RestCorner], tool: SC.ToolParams) throws -> [SC.OutputToolpath] {
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                 plungeRate: 300.0,
                                                                 stepdown: 1.0,
                                                                 stepoverPercentage: 0.4),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)
        return try generateRestToolpaths(corners: corners, tool: tool, settings: settings)
    }
}
