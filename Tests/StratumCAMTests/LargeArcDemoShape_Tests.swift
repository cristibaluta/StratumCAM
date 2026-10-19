//
//  LargeArcDemoShape_Tests.swift
//  StratumCAM
//
//  Backs the "Large Arc 300°" demos: a Pac-Man built from a 300° bulge arc (crossing the ±π
//  seam) closed by a wedge back to the center.
//

import Testing
import Foundation
@testable import StratumCAM

struct LargeArcDemoShape_Tests {

    private let deg = Double.pi / 180

    private func pacMan(reversed: Bool = false) -> SC.Contour {
        let mouth = 30 * deg
        let radius = 10.0
        let shape = SC.Geometry.polyline(
            vertices: [.init(SIMD2(radius * cos(mouth), radius * sin(mouth)), bulge: tan(300 * deg / 4)),
                       .init(SIMD2(radius * cos(-mouth), radius * sin(-mouth))),
                       .init(SIMD2(0, 0))],
            closed: true
        )
        return SC.Contour(entities: [.init(geometry: shape, reversed: reversed)], isClosed: true)
    }

    @Test("The 300° arc is measured as 300°, forward and reversed")
    func testLength() {
        let expected = 10.0 * 300 * deg + 10.0 + 10.0

        #expect(abs(pacMan().linearizedSegments.pathLength - expected) < 1e-6)
        #expect(abs(pacMan(reversed: true).linearizedSegments.pathLength - expected) < 1e-6)
    }

    @Test("Winding follows the direction of travel")
    func testWinding() {
        #expect(OffsetTools.isCCWWinding(pacMan().linearizedSegments))
        #expect(!OffsetTools.isCCWWinding(pacMan(reversed: true).linearizedSegments))
    }

    @Test("A tab on the 300° arc clamps part of the last pass to the tab floor")
    func testTabsOnLargeArc() throws {
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 0.5, stepoverPercentage: 0.4),
                                          safeZ: 5,
                                          targetDepth: -3)
        let operation: SC.MachiningOperation = .contour(
            side: .outside,
            direction: .climb,
            entry: .plunge,
            leadIn: nil,
            leadOut: nil,
            tabs: [SC.HoldingTab(positionRatio: 0.35, width: 6, height: 1.5)]
        )

        let paths = try SCEngine().generateToolpaths(from: [pacMan()],
                                                     tool: SC.ToolParams(diameter: 3.175),
                                                     settings: settings,
                                                     operation: operation)
        let lastPass = try #require(paths.first?.passes.last)
        let cutting = lastPass.waypoints.filter { $0.position.z < 0 }

        // Part of the last pass is held at the tab floor, the rest reaches full depth.
        #expect(cutting.contains { abs($0.position.z - (-1.5)) < 1e-9 })
        #expect(cutting.contains { abs($0.position.z - (-3.0)) < 1e-9 })
    }

    @Test("Reversed, inside, conventional profile of the same shape still generates")
    func testReversedInside() throws {
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 0.5, stepoverPercentage: 0.4),
                                          safeZ: 5,
                                          targetDepth: -1)
        let operation: SC.MachiningOperation = .contour(
            side: .inside,
            direction: .conventional,
            entry: .plunge,
            leadIn: nil,
            leadOut: nil,
            tabs: [SC.HoldingTab(positionRatio: 0.5, width: 6, height: 1.0)]
        )

        let paths = try SCEngine().generateToolpaths(from: [pacMan(reversed: true)],
                                                     tool: SC.ToolParams(diameter: 3.175),
                                                     settings: settings,
                                                     operation: operation)
        #expect(paths.count == 1)
        #expect(!(paths[0].passes.isEmpty))
    }
}
