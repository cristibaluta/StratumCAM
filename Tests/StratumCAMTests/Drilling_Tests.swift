//
//  Drilling.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

// Covers point-contour recognition and both plain and peck-cycle drill cycles for `.drilling`.

struct Drilling_Tests {

    // MARK: - Point recognition

    @Test("A single .point entity is recognized as a drill point")
    func testPointEntityIsRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(5, 7), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let point = engine.drillPoint(for: contour)

        #expect(point != nil, "Test Failed: expected a drill point")
        #expect(abs(point!.x - 5.0) < 1e-9 && abs(point!.y - 7.0) < 1e-9, "Test Failed: drill point XY mismatch")
    }

    @Test("A single closed circle is recognized as a drill point at its center")
    func testClosedCircleIsRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(entity: .circle(center: DXF.Point(3, 4), radius: 2.5, layer: "0", color: 7), reversed: false)
        ], isClosed: true)

        let point = engine.drillPoint(for: contour)

        #expect(point != nil, "Test Failed: expected a drill point")
        #expect(abs(point!.x - 3.0) < 1e-9 && abs(point!.y - 4.0) < 1e-9, "Test Failed: drill point should be the circle's center")
    }

    @Test("A circle marked as not closed is not treated as a drill point")
    func testOpenCircleIsNotRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(entity: .circle(center: DXF.Point(3, 4), radius: 2.5, layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        #expect(engine.drillPoint(for: contour) == nil, "Test Failed: an unclosed circle should not resolve to a drill point")
    }

    @Test("A line is not recognized as a drill point")
    func testLineIsNotRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        #expect(engine.drillPoint(for: contour) == nil, "Test Failed: a line should not resolve to a drill point")
    }

    @Test("A multi-entity contour is not recognized as a drill point")
    func testMultiEntityContourIsNotRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .point(at: DXF.Point(5, 5), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        #expect(engine.drillPoint(for: contour) == nil, "Test Failed: a multi-entity contour should not resolve to a single drill point")
    }

    // MARK: - Basic drill cycle

    @Test("A plain drill cycle plunges straight down and retracts at the point location")
    func testDrillingPlungesAndRetractsAtPointLocation() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 3.0, stepdown: 1.0)
        let settings = SC.MachineSettings(feedRate: 1000.0, plungeRate: 200.0, safeZ: 5.0, targetDepth: -8.0)

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(12, 20), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings, strategy: .drilling(peckDepth: nil))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 1, "Test Failed: a plain drill cycle should be a single pass")

        let waypoints = toolpath.passes[0].waypoints
        #expect(waypoints.count == 3, "Test Failed: expected rapid-plunge-retract, got \(waypoints.count) waypoints")

        // [0] Rapid to (12, 20) @ SafeZ
        let wp0 = waypoints[0]
        #expect(abs(wp0.position.x - 12.0) < 1e-9 && abs(wp0.position.y - 20.0) < 1e-9 && wp0.position.z == 5.0,
                "Test Failed: initial rapid move incorrect")
        if case .rapid = wp0.motion {} else {
            Issue.record("Test Failed: first waypoint motion must be .rapid")
        }

        // [1] Plunge straight to target depth
        let wp1 = waypoints[1]
        #expect(abs(wp1.position.x - 12.0) < 1e-9 && abs(wp1.position.y - 20.0) < 1e-9, "Test Failed: plunge XY mismatch")
        #expect(wp1.position.z == -8.0, "Test Failed: plunge Z mismatch")
        #expect(wp1.feedRate == 200.0, "Test Failed: plunge feed rate should match settings")
        if case .linear = wp1.motion {} else {
            Issue.record("Test Failed: plunge motion must be .linear")
        }

        // [2] Retract back to SafeZ
        let wp2 = waypoints[2]
        #expect(abs(wp2.position.x - 12.0) < 1e-9 && abs(wp2.position.y - 20.0) < 1e-9, "Test Failed: retract XY mismatch")
        #expect(wp2.position.z == 5.0, "Test Failed: retract Z mismatch")
        if case .rapid = wp2.motion {} else {
            Issue.record("Test Failed: retract motion must be .rapid")
        }
    }

    @Test("A drill cycle from a closed circle contour drills at the circle's center")
    func testDrillingUsesCircleCenterAsHoleLocation() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 4.0, stepdown: 1.0)
        let settings = SC.MachineSettings(feedRate: 1000.0, plungeRate: 250.0, safeZ: 6.0, targetDepth: -5.0)

        let contour = SC.Contour(entities: [
            .init(entity: .circle(center: DXF.Point(1, 2), radius: 2.0, layer: "0", color: 7), reversed: false)
        ], isClosed: true)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings, strategy: .drilling(peckDepth: nil))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let wp1 = toolpaths[0].passes[0].waypoints[1]
        #expect(abs(wp1.position.x - 1.0) < 1e-9 && abs(wp1.position.y - 2.0) < 1e-9, "Test Failed: drill should plunge at the circle's center")
        #expect(wp1.position.z == -5.0, "Test Failed: plunge Z mismatch")
    }

    @Test("A non-drill-point contour produces no drilling toolpath")
    func testDrillingNonDrillPointContourReturnsNoToolpath() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 3.0, stepdown: 1.0)
        let settings = SC.MachineSettings(feedRate: 1000.0, plungeRate: 200.0, safeZ: 5.0, targetDepth: -8.0)

        let contour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings, strategy: .drilling(peckDepth: nil))

        #expect(toolpaths.isEmpty, "Test Failed: a non-point contour should not produce a drilling toolpath")
    }

    // MARK: - Peck drilling

    @Test("Peck drilling with an evenly divisible depth produces exactly the right number of pecks")
    func testPeckDrillingEvenDivisionProducesExactPeckCount() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 3.0, stepdown: 1.0)
        let settings = SC.MachineSettings(feedRate: 1000.0, plungeRate: 200.0, safeZ: 5.0, retractZ: 1.0, targetDepth: 8.0)

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(10, 10), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings, strategy: .drilling(peckDepth: 4.0))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 1, "Test Failed: peck drilling should still be a single ToolpathPass")

        let waypoints = toolpath.passes[0].waypoints
        // 1 initial rapid to Safe Z, then 2 pecks x (plunge + retract) = 1 + 4 = 5 waypoints.
        #expect(waypoints.count == 5, "Test Failed: expected 5 waypoints for 2 pecks, got \(waypoints.count)")

        // [0] Initial rapid to Safe Z
        #expect(waypoints[0].position.z == 5.0, "Test Failed: initial move should be at Safe Z")
        if case .rapid = waypoints[0].motion {} else {
            Issue.record("Test Failed: initial waypoint motion must be .rapid")
        }

        // [1] First peck plunges to -4.0
        #expect(waypoints[1].position.z == -4.0, "Test Failed: first peck should stop at -4.0")
        #expect(waypoints[1].feedRate == 200.0, "Test Failed: peck plunge should use plunge feed rate")
        if case .linear = waypoints[1].motion {} else {
            Issue.record("Test Failed: peck plunge motion must be .linear")
        }

        // [2] Retract between pecks goes only to retractZ, not Safe Z
        #expect(waypoints[2].position.z == 1.0, "Test Failed: between-peck retract should go to retractZ")
        if case .rapid = waypoints[2].motion {} else {
            Issue.record("Test Failed: between-peck retract motion must be .rapid")
        }

        // [3] Second (final) peck plunges to full target depth
        #expect(waypoints[3].position.z == -8.0, "Test Failed: final peck should land exactly on target depth")
        if case .linear = waypoints[3].motion {} else {
            Issue.record("Test Failed: final peck plunge motion must be .linear")
        }

        // [4] Final retract goes all the way to Safe Z
        #expect(waypoints[4].position.z == 5.0, "Test Failed: final retract after last peck should go to Safe Z")
        if case .rapid = waypoints[4].motion {} else {
            Issue.record("Test Failed: final retract motion must be .rapid")
        }

        // XY stays fixed at the hole location throughout the cycle.
        for wp in waypoints {
            #expect(abs(wp.position.x - 10.0) < 1e-9 && abs(wp.position.y - 10.0) < 1e-9,
                    "Test Failed: peck cycle should stay at the hole's XY throughout")
        }
    }

    @Test("Peck drilling with an unevenly divisible depth ends exactly on target depth")
    func testPeckDrillingUnevenDivisionEndsAtTargetDepth() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 3.0, stepdown: 1.0)
        let settings = SC.MachineSettings(feedRate: 1000.0, plungeRate: 200.0, safeZ: 5.0, retractZ: 1.0, targetDepth: 10.0)

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings, strategy: .drilling(peckDepth: 4.0))

        let waypoints = toolpaths[0].passes[0].waypoints
        // 10.0 / 4.0 -> 2.5 -> rounds up to 3 pecks (4, 8, 10).
        // 1 initial rapid + 3 pecks x (plunge + retract) = 7 waypoints.
        #expect(waypoints.count == 7, "Test Failed: expected 7 waypoints for 3 pecks, got \(waypoints.count)")

        let plungeDepths = [waypoints[1].position.z, waypoints[3].position.z, waypoints[5].position.z]
        #expect(plungeDepths == [-4.0, -8.0, -10.0], "Test Failed: peck depths should be -4.0, -8.0, -10.0, got \(plungeDepths)")

        // Only the very last retract should reach Safe Z; the rest stop at retractZ.
        #expect(waypoints[2].position.z == 1.0 && waypoints[4].position.z == 1.0,
                "Test Failed: intermediate retracts should stop at retractZ")
        #expect(waypoints[6].position.z == 5.0, "Test Failed: final retract should reach Safe Z")
    }

    @Test("Peck drilling from a closed circle contour pecks at the circle's center")
    func testPeckDrillingUsesCircleCenterAsHoleLocation() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 4.0, stepdown: 1.0)
        let settings = SC.MachineSettings(feedRate: 1000.0, plungeRate: 250.0, safeZ: 6.0, retractZ: 1.5, targetDepth: 6.0)

        let contour = SC.Contour(entities: [
            .init(entity: .circle(center: DXF.Point(1, 2), radius: 2.0, layer: "0", color: 7), reversed: false)
        ], isClosed: true)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings, strategy: .drilling(peckDepth: 3.0))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let waypoints = toolpaths[0].passes[0].waypoints
        for wp in waypoints {
            #expect(abs(wp.position.x - 1.0) < 1e-9 && abs(wp.position.y - 2.0) < 1e-9,
                    "Test Failed: peck cycle should stay at the circle's center")
        }
        #expect(waypoints.last?.position.z == 6.0, "Test Failed: final retract should reach Safe Z")
    }

    @Test("A zero or negative peck depth falls back to a plain drill cycle")
    func testNonPositivePeckDepthFallsBackToPlainDrillCycle() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 3.0, stepdown: 1.0)
        let settings = SC.MachineSettings(feedRate: 1000.0, plungeRate: 200.0, safeZ: 5.0, targetDepth: 8.0)

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings, strategy: .drilling(peckDepth: 0.0))

        let waypoints = toolpaths[0].passes[0].waypoints
        #expect(waypoints.count == 3, "Test Failed: a non-positive peck depth should behave like a plain drill cycle")
        #expect(waypoints[1].position.z == -8.0, "Test Failed: plunge should still reach full target depth")
    }
}
