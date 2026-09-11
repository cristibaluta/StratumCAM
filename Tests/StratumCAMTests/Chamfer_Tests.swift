//
//  Chamfer_Tests.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Testing
import SwiftDXF
import simd
@testable import StratumCAM

struct Chamfer_Tests {

    @Test("Chamfer honors climb vs conventional direction")
    func testChamferHonorsDirection() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .vBit, diameter: 6.0, stepdown: 1.0, vAngle: 90.0)
        let settings = SC.MachineSettings(feedRate: 1000, plungeRate: 300, safeZ: 5.0, targetDepth: -1.0)

        // CCW square
        let square = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(10, 0), b: DXF.Point(10, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(10, 10), b: DXF.Point(0, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, 10), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)

        let climbParams = SC.ChamferParams(width: 1.0, side: .outside, direction: .climb)
        let conventionalParams = SC.ChamferParams(width: 1.0, side: .outside, direction: .conventional)

        let climbPath = engine.generateToolpaths(from: [square], tool: tool, settings: settings,
                                                  strategy: .chamfer(params: climbParams)).first
        let conventionalPath = engine.generateToolpaths(from: [square], tool: tool, settings: settings,
                                                          strategy: .chamfer(params: conventionalParams)).first

        // Same geometry, opposite travel direction -> waypoint order should differ.
        #expect(climbPath?.passes.first?.waypoints != conventionalPath?.passes.first?.waypoints)
    }
}
