//
//  Point.swift
//  Stratum CNC
//
//  Created by Cristian Baluta on 10.09.2026.
//

import Testing
import SwiftDXF
import simd
@testable import StratumCAM

// When engraving we usually do a single pass, so we are gonna test that

struct Engraving_Tests {

    @Test func testEngravingLine() {
        let engine = SCEngine()

        // 1. Setup Test Parameters
        let tool = SC.ToolParams(diameter: 3.175, stepdown: 0.1)
        let settings = SC.MachineSettings(feedRate: 1000.0,
                                          plungeRate: 300.0,
                                          safeZ: 5.0,
                                          targetDepth: -0.1)

        let lineEntity = DXF.Entity.line(a: DXF.Point(0, 0),
                                         b: DXF.Point(10, 0),
                                         layer: "0",
                                         color: 7)

        let contour = SC.Contour(
            entities: [
                SC.Contour.Chained(entity: lineEntity, reversed: false)
            ],
            isClosed: false
        )

        // 3. Execute Engine
        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings)

        // 4. #expections

        // #expect Output Structures
        #expect(toolpaths.count == 1)
        let toolpath = toolpaths[0]

        // Depth: -0.1 with stepdown 0.1 should produce exactly 1 pass
        #expect(toolpath.passes.count == 1)

        // Inspect Pass 1 Waypoints
        let firstPass = toolpath.passes[0]
        #expect(firstPass.depthZ == -0.1)

        // Waypoint structure expected:
        // [0] Rapid to (0,0) @ SafeZ (5.0)
        // [1] Plunge to (0,0) @ TargetZ (-0.1)
        // [2] Linear move to line end (10, 0) @ TargetZ
        // [3] Retract to (10, 0) @ SafeZ (5.0)
        #expect(firstPass.waypoints.count == 4)

        // Verify Rapid Move Above Start
        let wp0 = firstPass.waypoints[0]
        #expect(wp0.position.x == 0 && wp0.position.y == 0 && wp0.position.z == 5.0, "Test Failed: Initial rapid move incorrect")
        if case .rapid = wp0.motion {} else {
            Issue.record("Test Failed: First waypoint motion must be .rapid")
        }

        // Verify Plunge Move
        let wp1 = firstPass.waypoints[1]
        #expect(wp1.position.z == -0.1, "Test Failed: Plunge Z value incorrect")
        #expect(wp1.feedRate == 300.0, "Test Failed: Plunge feed rate should match settings")

        // Verify Line Motion
        let wp2 = firstPass.waypoints[2]
        #expect(abs(wp2.position.x - 10.0) < 1e-5, "Test Failed: Arc end X mismatch")
        #expect(abs(wp2.position.y - 0.0) < 1e-5, "Test Failed: Arc end Y mismatch")
        if case .linear = wp2.motion {
//            #expect(center.x == 10.0 && center.y == 5.0, "Test Failed: Arc center mismatch")
        } else {
            Issue.record("Test Failed: Expected Linear motion")
        }

        // Verify Retract Move
        let wp4 = firstPass.waypoints[3]
        #expect(abs(wp4.position.x - 10.0) < 1e-5, "Test Failed: Arc end X mismatch")
        #expect(abs(wp4.position.y - 0.0) < 1e-5, "Test Failed: Arc end Y mismatch")
        #expect(wp4.position.z == 5.0, "Test Failed: Final retract Z mismatch")
    }

    @Test func testEngravingArc() {
        let engine = SCEngine()

        // 1. Setup Test Parameters
        let tool = SC.ToolParams(diameter: 3.175, stepdown: 0.1)
        let settings = SC.MachineSettings(feedRate: 1000.0,
                                          plungeRate: 300.0,
                                          safeZ: 5.0,
                                          targetDepth: -0.1)

        let arcEntity = DXF.Entity.arc(
            center: DXF.Point(10, 5),
            radius: 5.0,
            startDeg: 270.0, // Bottom of circle (10, 0)
            endDeg: 360.0,   // Right side of circle (15, 5)
            layer: "0",
            color: 7
        )

        let contour = SC.Contour(
            entities: [
                SC.Contour.Chained(entity: arcEntity, reversed: false)
            ],
            isClosed: false
        )

        // 3. Execute Engine
        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings)

        // 4. #expections

        // #expect Output Structures
        #expect(toolpaths.count == 1, "Test Failed: Expected 1 output toolpath")
        let toolpath = toolpaths[0]

        // Depth: -2.0 with stepdown 1.0 should produce exactly 2 passes (-1.0, -2.0)
        #expect(toolpath.passes.count == 1, "Test Failed: Expected 1 passes, got \(toolpath.passes.count)")

        // Inspect Pass 1 Waypoints
        let firstPass = toolpath.passes[0]
        #expect(firstPass.depthZ == -0.1, "Test Failed: First pass Z should be -0.1, got \(firstPass.depthZ)")

        // Waypoint structure expected:
        // [0] Rapid to (0,0) @ SafeZ (5.0)
        // [1] Plunge to (0,0) @ TargetZ (-0.1)
        // [2] Arc move to (10, 0) @ TargetZ
        // [3] Retract to (10, 0) @ SafeZ (5.0)
        #expect(firstPass.waypoints.count == 4, "Test Failed: Expected 5 waypoints in pass, got \(firstPass.waypoints.count)")

        // Verify Rapid Move Above Start
        let wp0 = firstPass.waypoints[0]
        #expect(abs(wp0.position.x - 10) < 1e-5 && abs(wp0.position.y - 0) < 1e-5 && wp0.position.z == 5.0, "Test Failed: Initial rapid move incorrect")
        if case .rapid = wp0.motion {} else {
            Issue.record("Test Failed: First waypoint motion must be .rapid")
        }

        // Verify Plunge Move
        let wp1 = firstPass.waypoints[1]
        #expect(wp1.position.z == -0.1, "Test Failed: Plunge Z value incorrect")
        #expect(wp1.feedRate == 300.0, "Test Failed: Plunge feed rate should match settings")

        // Verify Arc Motion
        let wp2 = firstPass.waypoints[2]
        #expect(abs(wp2.position.x - 15.0) < 1e-5, "Test Failed: Arc end X mismatch")
        #expect(abs(wp2.position.y - 5.0) < 1e-5, "Test Failed: Arc end Y mismatch")
        if case .arcCCW(let center) = wp2.motion {
            #expect(center.x == 10.0 && center.y == 5.0, "Test Failed: Arc center mismatch")
        } else {
            Issue.record("Test Failed: Expected Linear motion")
        }

        // Verify Retract Move
        let wp3 = firstPass.waypoints[3]
        #expect(abs(wp3.position.x - 15.0) < 1e-5, "Test Failed: Arc end X mismatch")
        #expect(abs(wp3.position.y - 5.0) < 1e-5, "Test Failed: Arc end Y mismatch")
        #expect(wp3.position.z == 5.0, "Test Failed: Final retract Z mismatch")
    }

    @Test func testMultiplePasses() {
        let engine = SCEngine()

        // 1. Setup Test Parameters
        let tool = SC.ToolParams(diameter: 3.175, stepdown: 0.1)
        let settings = SC.MachineSettings(feedRate: 1000.0,
                                          plungeRate: 300.0,
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let lineEntity = DXF.Entity.line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7)

        let contour = SC.Contour(
            entities: [
                SC.Contour.Chained(entity: lineEntity, reversed: false)
            ],
            isClosed: false
        )

        // #expect Output Structures
        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings)
        #expect(toolpaths.count == 1, "Test Failed: Expected 1 output toolpath")

        // Depth: -1.0 with stepdown 0.1 should produce 10 passes
        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 10)
    }
}
