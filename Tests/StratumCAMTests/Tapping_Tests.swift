//
//  Tapping.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

// Covers Step 2D.1 (the helical thread-milling core -- a continuous helix stepping down
// by `pitch` per revolution around a hole/boss's nominal diameter, radius-compensated for
// `isInternal`, finishing with a flat closing lap) but not yet Step 2D.2 (wiring
// `direction` into the helix's own winding sense -- see `buildTappingToolpath`'s own doc
// comment on that split).

struct Tapping_Tests {

    /// Handy small helper: a closed circle contour marking a hole/boss of `diameter`,
    /// centered at `center` -- the same "closed circle marks the feature" shape
    /// `tapCircle(for:)` recognizes.
    private func circleContour(center: (Double, Double), diameter: Double) -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .circle(center: DXF.Point(center.0, center.1), radius: diameter / 2.0, layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    @Test("Thread milling steps down by pitch each revolution and finishes with a flat closing lap")
    func testThreadMillingStepsDownByPitchWithClosingLap() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0) // tool radius 1.5
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -3.0)

        let contour = circleContour(center: (0, 0), diameter: 10.0) // hole radius 5.0

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 1, "Test Failed: thread milling should be a single pass")

        let waypoints = toolpath.passes[0].waypoints
        // [0] Rapid to the mill's 3 o'clock start point @ SafeZ
        // [1] Rapid down to the top of stock (Z=0) at the same XY
        // [2...9]   Turn 1: 8 arc waypoints, 0 -> -1.0
        // [10...17] Turn 2: 8 arc waypoints, -1.0 -> -2.0
        // [18...25] Turn 3: 8 arc waypoints, -2.0 -> -3.0
        // [26...33] Closing lap: 8 arc waypoints, flat at -3.0
        // [34] Retract to SafeZ
        #expect(waypoints.count == 35, "Test Failed: expected 2 + 4*8 + 1 waypoints, got \(waypoints.count)")

        let millRadius = 5.0 - 1.5 // hole radius - tool radius

        let wp0 = waypoints[0]
        #expect(abs(wp0.position.x - millRadius) < 1e-9 && abs(wp0.position.y) < 1e-9 && wp0.position.z == 5.0,
                "Test Failed: initial rapid should land at the mill radius, 3 o'clock, at Safe Z")
        if case .rapid = wp0.motion {} else {
            Issue.record("Test Failed: first waypoint motion must be .rapid")
        }

        let wp1 = waypoints[1]
        #expect(wp1.position.z == 0.0, "Test Failed: second waypoint should rapid down to the top of stock (Z=0)")
        if case .rapid = wp1.motion {} else {
            Issue.record("Test Failed: second waypoint motion must be .rapid")
        }

        // End of turn 1: back at the start XY, one pitch deeper.
        let endOfTurn1 = waypoints[9]
        #expect(endOfTurn1.position.z == -1.0, "Test Failed: turn 1 should end exactly one pitch down")
        #expect(abs(endOfTurn1.position.x - millRadius) < 1e-9 && abs(endOfTurn1.position.y) < 1e-9,
                "Test Failed: a full revolution should return to the start XY")
        if case .arcCCW = endOfTurn1.motion {} else {
            Issue.record("Test Failed: thread milling arcs should be .arcCCW")
        }

        // End of turn 2 and turn 3.
        #expect(waypoints[17].position.z == -2.0, "Test Failed: turn 2 should end two pitches down")
        #expect(waypoints[25].position.z == -3.0, "Test Failed: turn 3 should end at full target depth")

        // Closing lap: every waypoint stays flat at the final depth.
        for i in 26...33 {
            #expect(waypoints[i].position.z == -3.0, "Test Failed: closing lap waypoint \(i) should stay flat at target depth")
        }
        #expect(abs(waypoints[33].position.x - millRadius) < 1e-9 && abs(waypoints[33].position.y) < 1e-9,
                "Test Failed: closing lap should also return to the start XY")

        // Final retract, straight up from the closing lap's own end point.
        let retract = waypoints[34]
        #expect(retract.position.z == 5.0, "Test Failed: final retract should reach Safe Z")
        #expect(abs(retract.position.x - millRadius) < 1e-9 && abs(retract.position.y) < 1e-9,
                "Test Failed: retract should lift straight up from the closing lap's end point")
        if case .rapid = retract.motion {} else {
            Issue.record("Test Failed: final retract motion must be .rapid")
        }
    }

    @Test("Internal threading compensates the mill radius inward from the hole's diameter")
    func testInternalThreadingOffsetsInward() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0) // tool radius 2.0
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = circleContour(center: (10, 20), diameter: 12.0) // hole radius 6.0

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 2.0, isInternal: true, direction: .climb))

        let start = toolpaths[0].passes[0].waypoints[0]
        // Expected mill radius: 6.0 - 2.0 = 4.0, offset from the hole's own center.
        #expect(abs(start.position.x - (10.0 + 4.0)) < 1e-9 && abs(start.position.y - 20.0) < 1e-9,
                "Test Failed: internal threading should orbit inside the drawn diameter by the tool's radius")
    }

    @Test("External threading compensates the mill radius outward from the boss's diameter")
    func testExternalThreadingOffsetsOutward() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0) // tool radius 2.0
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = circleContour(center: (10, 20), diameter: 12.0) // boss radius 6.0

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 2.0, isInternal: false, direction: .climb))

        let start = toolpaths[0].passes[0].waypoints[0]
        // Expected mill radius: 6.0 + 2.0 = 8.0, offset from the boss's own center.
        #expect(abs(start.position.x - (10.0 + 8.0)) < 1e-9 && abs(start.position.y - 20.0) < 1e-9,
                "Test Failed: external threading should orbit outside the drawn diameter by the tool's radius")
    }

    @Test("Thread milling a hole not much bigger than the tool itself produces no toolpath")
    func testToolTooLargeForInternalHoleReturnsNoToolpath() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 10.0) // tool radius 5.0
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = circleContour(center: (0, 0), diameter: 8.0) // hole radius 4.0, smaller than the tool radius

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

        #expect(toolpaths.isEmpty, "Test Failed: a tool wider than the hole radius shouldn't produce a thread-milling toolpath")
    }

    @Test("A non-circle contour produces no tapping toolpath")
    func testNonCircleContourReturnsNoToolpath() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

        #expect(toolpaths.isEmpty, "Test Failed: tapping needs a diameter to compensate against, so a bare point shouldn't produce a toolpath")
    }

    @Test("A zero pitch produces no toolpath")
    func testZeroPitchReturnsNoToolpath() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 0.0, isInternal: true, direction: .climb))

        #expect(toolpaths.isEmpty, "Test Failed: a zero pitch has no well-defined helix and shouldn't produce a toolpath")
    }

    @Test("Tapping a batch of holes assigns each toolpath to its own hole location")
    func testTappingBatchOfHolesEachGetsOwnToolpath() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0) // tool radius 1.5
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let centers: [(Double, Double)] = [(0, 0), (20, 0), (20, 20), (0, 20)]
        let contours = centers.map { circleContour(center: $0, diameter: 10.0) } // hole radius 5.0

        let toolpaths = engine.generateToolpaths(from: contours, tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

        #expect(toolpaths.count == 4, "Test Failed: expected one thread-milling toolpath per hole contour")

        let millRadius = 5.0 - 1.5
        for (toolpath, center) in zip(toolpaths, centers) {
            let start = toolpath.passes[0].waypoints[0]
            #expect(abs(start.position.x - (center.0 + millRadius)) < 1e-9 && abs(start.position.y - center.1) < 1e-9,
                    "Test Failed: toolpath was assigned to the wrong hole")
        }
    }
}
