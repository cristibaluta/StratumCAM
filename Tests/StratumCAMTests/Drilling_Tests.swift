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

// Covers point-contour recognition and basic (non-peck) drill cycles for `.drilling`.

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

    @Test("Peck drilling is not yet implemented and returns no toolpath")
    func testDrillingWithPeckDepthNotYetImplementedReturnsNil() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 3.0, stepdown: 1.0)
        let settings = SC.MachineSettings(feedRate: 1000.0, plungeRate: 200.0, safeZ: 5.0, targetDepth: -8.0)

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings, strategy: .drilling(peckDepth: 1.5))

        #expect(toolpaths.isEmpty, "Test Failed: peck drilling should return no toolpath until Step 1.3 implements it")
    }
}
