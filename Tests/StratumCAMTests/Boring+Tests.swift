//
//  Boring_Tests.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

// Covers Step 2C.1 (the basic boring cycle -- rapid to the hole's edge, plunge, circular
// interpolation at targetDiameter / 2 around the hole center, retract) and Step 2C.2's
// shiftRetract half (the off-center shift before the final retract move; dwellTime is a
// G-code-only concern and is covered separately in GCode_Boring_Tests.swift).

struct Boring_Tests {

    @Test("A basic boring cycle plunges at the hole's edge and orbits the center at the target radius")
    func testBoringPlungesAndOrbitsAtTargetRadius() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -8.0)

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(12, 20), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .boring(targetDiameter: 10.0, dwellTime: nil, shiftRetract: false))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 1, "Test Failed: a basic boring cycle should be a single pass")

        let waypoints = toolpath.passes[0].waypoints
        // [0] Rapid to bore edge @ SafeZ
        // [1] Plunge to depth @ bore edge
        // [2] Arc to the opposite side of the bore @ depth
        // [3] Arc back to the bore edge @ depth
        // [4] Retract to SafeZ
        #expect(waypoints.count == 5, "Test Failed: expected rapid-plunge-arc-arc-retract, got \(waypoints.count) waypoints")

        let radius = 5.0 // targetDiameter 10.0 / 2

        // [0] Rapid to (17, 20) @ SafeZ -- the hole center offset by radius along +X
        let wp0 = waypoints[0]
        #expect(abs(wp0.position.x - (12.0 + radius)) < 1e-9 && abs(wp0.position.y - 20.0) < 1e-9 && wp0.position.z == 5.0,
                "Test Failed: initial rapid move should land on the bore's edge at Safe Z")
        if case .rapid = wp0.motion {} else {
            Issue.record("Test Failed: first waypoint motion must be .rapid")
        }

        // [1] Plunge straight down to target depth, still at the bore's edge (off-center)
        let wp1 = waypoints[1]
        #expect(abs(wp1.position.x - (12.0 + radius)) < 1e-9 && abs(wp1.position.y - 20.0) < 1e-9, "Test Failed: plunge XY mismatch")
        #expect(wp1.position.z == -8.0, "Test Failed: plunge Z mismatch")
        #expect(wp1.feedRate == 200.0, "Test Failed: plunge feed rate should match settings")
        if case .linear = wp1.motion {} else {
            Issue.record("Test Failed: plunge motion must be .linear")
        }

        // [2] First half-circle arc, centered on the hole, ending on the opposite side
        let wp2 = waypoints[2]
        #expect(abs(wp2.position.x - (12.0 - radius)) < 1e-9 && abs(wp2.position.y - 20.0) < 1e-9, "Test Failed: first arc endpoint mismatch")
        #expect(wp2.position.z == -8.0, "Test Failed: first arc should stay at target depth")
        if case .arcCCW(let center) = wp2.motion {
            #expect(abs(center.x - 12.0) < 1e-9 && abs(center.y - 20.0) < 1e-9, "Test Failed: first arc center should be the hole center")
        } else {
            Issue.record("Test Failed: expected arcCCW motion for the first half of the circular interpolation")
        }

        // [3] Second half-circle arc, back to the starting edge point
        let wp3 = waypoints[3]
        #expect(abs(wp3.position.x - (12.0 + radius)) < 1e-9 && abs(wp3.position.y - 20.0) < 1e-9, "Test Failed: second arc endpoint mismatch")
        #expect(wp3.position.z == -8.0, "Test Failed: second arc should stay at target depth")
        if case .arcCCW(let center) = wp3.motion {
            #expect(abs(center.x - 12.0) < 1e-9 && abs(center.y - 20.0) < 1e-9, "Test Failed: second arc center should be the hole center")
        } else {
            Issue.record("Test Failed: expected arcCCW motion for the second half of the circular interpolation")
        }

        // [4] Retract back to Safe Z, still above the bore's edge
        let wp4 = waypoints[4]
        #expect(abs(wp4.position.x - (12.0 + radius)) < 1e-9 && abs(wp4.position.y - 20.0) < 1e-9, "Test Failed: retract XY mismatch")
        #expect(wp4.position.z == 5.0, "Test Failed: retract Z mismatch")
        if case .rapid = wp4.motion {} else {
            Issue.record("Test Failed: retract motion must be .rapid")
        }
    }

    @Test("A boring cycle from a closed circle contour bores centered on the circle's center")
    func testBoringUsesCircleCenterAsHoleLocation() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 250.0, stepdown: 1.0),
                                          safeZ: 6.0,
                                          targetDepth: -5.0)

        let contour = SC.Contour(entities: [
            .init(entity: .circle(center: DXF.Point(1, 2), radius: 3.0, layer: "0", color: 7), reversed: false)
        ], isClosed: true)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .boring(targetDiameter: 8.0, dwellTime: nil, shiftRetract: false))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let waypoints = toolpaths[0].passes[0].waypoints

        // Both arcs' centers should be the circle's own center, independent of its own radius.
        if case .arcCCW(let center) = waypoints[2].motion {
            #expect(abs(center.x - 1.0) < 1e-9 && abs(center.y - 2.0) < 1e-9, "Test Failed: bore should be centered on the circle's center")
        } else {
            Issue.record("Test Failed: expected arcCCW motion")
        }
        #expect(abs(waypoints[1].position.x - (1.0 + 4.0)) < 1e-9, "Test Failed: plunge should sit targetDiameter / 2 off the hole center")
        #expect(waypoints[1].position.z == -5.0, "Test Failed: plunge Z mismatch")
    }

    @Test("A non-drill-point contour produces no boring toolpath")
    func testBoringNonDrillPointContourReturnsNoToolpath() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -8.0)

        let contour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .boring(targetDiameter: 10.0, dwellTime: nil, shiftRetract: false))

        #expect(toolpaths.isEmpty, "Test Failed: a non-point contour should not produce a boring toolpath")
    }

    @Test("Boring a batch of holes assigns each toolpath to its own hole location")
    func testBoringBatchOfHolesEachGetsOwnToolpath() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -8.0)

        let points: [(Double, Double)] = [(0, 0), (10, 0), (10, 10), (0, 10)]
        let contours = points.map { x, y in
            SC.Contour(entities: [
                .init(entity: .point(at: DXF.Point(x, y), layer: "0", color: 7), reversed: false)
            ], isClosed: false)
        }

        let toolpaths = try engine.generateToolpaths(from: contours, tool: tool, settings: settings,
                                                  operation: .boring(targetDiameter: 6.0, dwellTime: nil, shiftRetract: false))

        #expect(toolpaths.count == 4, "Test Failed: expected one boring toolpath per point contour")

        for (toolpath, expected) in zip(toolpaths, points) {
            let waypoints = toolpath.passes[0].waypoints
            #expect(waypoints.count == 5, "Test Failed: each bore should contain rapid-plunge-arc-arc-retract")
            #expect(abs(waypoints[1].position.x - (expected.0 + 3.0)) < 1e-9 && abs(waypoints[1].position.y - expected.1) < 1e-9,
                    "Test Failed: toolpath was assigned to the wrong hole")
        }
    }

    // MARK: - Shift retract (Step 2C.2)

    @Test("shiftRetract off keeps the retract straight above the bore's edge")
    func testShiftRetractFalseRetractsStraightUp() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -8.0)

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .boring(targetDiameter: 10.0, dwellTime: nil, shiftRetract: false))

        let waypoints = toolpaths[0].passes[0].waypoints
        #expect(waypoints.count == 5, "Test Failed: with shiftRetract off there should be no extra shift waypoint")

        // Retract should sit directly above the bore's edge (5.0, 0) where the circular pass finished.
        let retract = waypoints[4]
        #expect(abs(retract.position.x - 5.0) < 1e-9 && abs(retract.position.y - 0.0) < 1e-9, "Test Failed: retract should stay at the bore's edge")
        #expect(retract.position.z == 5.0, "Test Failed: retract Z mismatch")
        if case .rapid = retract.motion {} else {
            Issue.record("Test Failed: retract motion must be .rapid")
        }
    }

    @Test("shiftRetract on inserts a linear move off the wall, toward center, before retracting")
    func testShiftRetractTrueInsertsShiftBeforeRetract() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0) // tool radius 3.0
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -8.0)

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .boring(targetDiameter: 10.0, dwellTime: nil, shiftRetract: true)) // bore radius 5.0

        let waypoints = toolpaths[0].passes[0].waypoints
        // [0] rapid, [1] plunge, [2] arc, [3] arc, [4] shift, [5] retract
        #expect(waypoints.count == 6, "Test Failed: expected an extra shift waypoint before the retract, got \(waypoints.count) waypoints")

        // [4] Shift inward by the tool's radius (3.0), still at depth
        let shift = waypoints[4]
        #expect(abs(shift.position.x - 2.0) < 1e-9 && abs(shift.position.y - 0.0) < 1e-9, "Test Failed: shift should move inward by the tool radius")
        #expect(shift.position.z == -8.0, "Test Failed: shift should stay at target depth")
        if case .linear = shift.motion {} else {
            Issue.record("Test Failed: shift motion must be .linear")
        }

        // [5] Retract up from the shifted point, not the bore's edge
        let retract = waypoints[5]
        #expect(abs(retract.position.x - 2.0) < 1e-9 && abs(retract.position.y - 0.0) < 1e-9, "Test Failed: retract should lift from the shifted point")
        #expect(retract.position.z == 5.0, "Test Failed: retract Z mismatch")
        if case .rapid = retract.motion {} else {
            Issue.record("Test Failed: retract motion must be .rapid")
        }
    }

    @Test("shiftRetract clamps to the hole center when the tool radius exceeds the bore radius")
    func testShiftRetractClampsToHoleCenter() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 20.0) // tool radius 10.0, wider than the bore
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -8.0)

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .boring(targetDiameter: 6.0, dwellTime: nil, shiftRetract: true)) // bore radius 3.0

        let shift = toolpaths[0].passes[0].waypoints[4]
        // Clamped to the hole's own center (0, 0) rather than overshooting past it.
        #expect(abs(shift.position.x - 0.0) < 1e-9 && abs(shift.position.y - 0.0) < 1e-9, "Test Failed: shift should clamp to the hole center, not overshoot past it")
    }

    @Test("shiftRetract lands exactly on the hole center when the tool radius exactly matches the bore radius")
    func testShiftRetractExactlyReachesHoleCenterAtBoundary() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 10.0) // tool radius 5.0, exactly the bore radius
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -8.0)

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .boring(targetDiameter: 10.0, dwellTime: nil, shiftRetract: true)) // bore radius 5.0

        let shift = toolpaths[0].passes[0].waypoints[4]
        #expect(abs(shift.position.x - 0.0) < 1e-9 && abs(shift.position.y - 0.0) < 1e-9,
                "Test Failed: an exactly-matching tool/bore radius should shift precisely to the hole center, not stop short or overshoot")
    }

    // MARK: - Feed rates

    @Test("The circular interpolation cuts at the cutting feed rate, not the plunge rate")
    func testCircularInterpolationUsesCuttingFeedRateNotPlungeRate() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1200.0, plungeRate: 150.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -8.0)

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .boring(targetDiameter: 10.0, dwellTime: nil, shiftRetract: false))

        let waypoints = toolpaths[0].passes[0].waypoints
        #expect(waypoints[1].feedRate == 150.0, "Test Failed: the plunge should use the plunge feed rate")
        #expect(waypoints[2].feedRate == 1200.0, "Test Failed: the first arc should cut at the ordinary feed rate")
        #expect(waypoints[3].feedRate == 1200.0, "Test Failed: the second arc should cut at the ordinary feed rate")
        #expect(waypoints[4].feedRate == 1200.0, "Test Failed: the retract move should carry the ordinary feed rate")
    }
}
