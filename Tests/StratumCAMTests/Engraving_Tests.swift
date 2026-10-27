//
//  Point.swift
//  Stratum CNC
//
//  Created by Cristian Baluta on 10.09.2026.
//

import Testing
import simd
@testable import StratumCAM

// When engraving we usually do a single pass, so we are gonna test that a single pass will start and end in the right place

struct Engraving_Tests {

    @Test("Engrave a single line")
    func testEngravingLine() throws {
        let engine = SCEngine()

        // 1. Setup Test Parameters
        let tool = SC.ToolParams(diameter: 3.175)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                    plungeRate: 300.0,
                                                                    stepdown: 0.1, stepoverPercentage: 0.4),
                                          safeZ: 5.0,
                                          targetDepth: -0.1)

        let lineEntity = SC.Geometry.line(a: SIMD2<Double>(0, 0),
                                         b: SIMD2<Double>(10, 0))

        let contour = SC.Contour(
            entities: [
                SC.Contour.Chained(geometry: lineEntity, reversed: false)
            ],
            isClosed: false
        )

        // 3. Execute Engine
        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings, operation: .engrave())

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
        #expect(wp2.position.x ~= 10.0, "Test Failed: Arc end X mismatch")
        #expect(wp2.position.y ~= 0.0, "Test Failed: Arc end Y mismatch")
        if case .linear = wp2.motion {
            // All good
        } else {
            Issue.record("Test Failed: Expected Linear motion")
        }

        // Verify Retract Move
        let wp4 = firstPass.waypoints[3]
        #expect(wp4.position.x ~= 10.0, "Test Failed: Arc end X mismatch")
        #expect(wp4.position.y ~= 0.0, "Test Failed: Arc end Y mismatch")
        #expect(wp4.position.z == 5.0, "Test Failed: Final retract Z mismatch")
    }

    @Test("Engrave a single arc")
    func testEngravingArc() throws {
        let engine = SCEngine()

        // 1. Setup Test Parameters
        let tool = SC.ToolParams(diameter: 3.175)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                    plungeRate: 300.0,
                                                                    stepdown: 0.1, stepoverPercentage: 0.4),
                                          safeZ: 5.0,
                                          targetDepth: -0.1)

        let arcEntity = SC.Geometry.arc(
            center: SIMD2<Double>(10, 5),
            radius: 5.0,
            startDeg: 270.0, // Bottom of circle (10, 0)
            endDeg: 360.0   // Right side of circle (15, 5)
        )

        let contour = SC.Contour(
            entities: [
                SC.Contour.Chained(geometry: arcEntity, reversed: false)
            ],
            isClosed: false
        )

        // 3. Execute Engine
        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings, operation: .engrave())

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
        #expect(wp0.position.x ~= 10 && wp0.position.y ~= 0 && wp0.position.z == 5.0, "Test Failed: Initial rapid move incorrect")
        if case .rapid = wp0.motion {} else {
            Issue.record("Test Failed: First waypoint motion must be .rapid")
        }

        // Verify Plunge Move
        let wp1 = firstPass.waypoints[1]
        #expect(wp1.position.z == -0.1, "Test Failed: Plunge Z value incorrect")
        #expect(wp1.feedRate == 300.0, "Test Failed: Plunge feed rate should match settings")

        // Verify Arc Motion
        let wp2 = firstPass.waypoints[2]
        #expect(wp2.position.x ~= 15.0, "Test Failed: Arc end X mismatch")
        #expect(wp2.position.y ~= 5.0, "Test Failed: Arc end Y mismatch")
        if case .arcCCW(let center) = wp2.motion {
            #expect(center.x == 10.0 && center.y == 5.0, "Test Failed: Arc center mismatch")
        } else {
            Issue.record("Test Failed: Expected Linear motion")
        }

        // Verify Retract Move
        let wp3 = firstPass.waypoints[3]
        #expect(wp3.position.x ~= 15.0, "Test Failed: Arc end X mismatch")
        #expect(wp3.position.y ~= 5.0, "Test Failed: Arc end Y mismatch")
        #expect(wp3.position.z == 5.0, "Test Failed: Final retract Z mismatch")
    }

    @Test("Test that we can generate multiple passes for a deep targetDepth")
    func testMultiplePasses() throws {
        let engine = SCEngine()

        // 1. Setup Test Parameters
        let tool = SC.ToolParams(diameter: 3.175)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                    plungeRate: 300.0,
                                                                    stepdown: 0.1, stepoverPercentage: 0.4),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let lineEntity = SC.Geometry.line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(10, 0))

        let contour = SC.Contour(
            entities: [
                SC.Contour.Chained(geometry: lineEntity, reversed: false)
            ],
            isClosed: false
        )

        // #expect Output Structures
        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings, operation: .engrave())
        #expect(toolpaths.count == 1, "Test Failed: Expected 1 output toolpath")

        // Depth: -1.0 with stepdown 0.1 should produce 10 passes
        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 10)
    }

    // MARK: - Entry strategy

    private func rampTestSettings(targetDepth: Double, stepdown: Double) -> SC.MachineSettings {
        SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                   plungeRate: 300.0,
                                                   stepdown: stepdown, stepoverPercentage: 0.4),
                           safeZ: 5.0,
                           targetDepth: targetDepth)
    }

    private func straightLine() -> SC.Contour {
        SC.Contour(
            entities: [
                SC.Contour.Chained(geometry: SC.Geometry.line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(10, 0)),
                                   reversed: false)
            ],
            isClosed: false
        )
    }

    @Test("Engrave with a ramp entry eases down along the line instead of plunging")
    func testEngravingRampEntry() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 3.175)
        let settings = rampTestSettings(targetDepth: -0.1, stepdown: 0.1)

        let toolpaths = try engine.generateToolpaths(from: [straightLine()],
                                                     tool: tool,
                                                     settings: settings,
                                                     operation: .engrave(entry: .ramp(angleDegrees: 2.0)))
        #expect(toolpaths.count == 1)
        let pass = toolpaths[0].passes[0]
        let waypoints = pass.waypoints

        // Rapid above the start, rapid down to the top of the stock, ramp legs, trace, retract.
        #expect(waypoints.count >= 5)
        #expect(waypoints[0].position.z == 5.0)
        #expect(waypoints[1].position.z == 0.0, "The ramp starts from the top of the stock, not from safeZ")
        if case .rapid = waypoints[1].motion {} else {
            Issue.record("Test Failed: The move down to the ramp start must be a rapid")
        }

        // The first cutting move is not a vertical plunge: it travels along the line while descending.
        let firstCut = waypoints[2]
        #expect(firstCut.position.x > 0.0, "Test Failed: Ramp must travel along the line")
        #expect(firstCut.position.z < 0.0 && firstCut.position.z > -0.1)
        #expect(firstCut.feedRate == 300.0, "Test Failed: Ramp moves use the plunge feed rate")

        // The descent never goes deeper than the pass, and the whole line is cut at full depth.
        #expect(waypoints.allSatisfy { $0.position.z >= -0.1 - 1e-9 })
        let trace = waypoints[waypoints.count - 2]
        #expect(trace.position.x ~= 10.0 && trace.position.y ~= 0.0 && trace.position.z ~= -0.1)
        #expect(trace.feedRate == 1000.0)

        // Ramp legs finish back on the start at depth, ready for the trace.
        let beforeTrace = waypoints[waypoints.count - 3]
        #expect(beforeTrace.position.x ~= 0.0 && beforeTrace.position.z ~= -0.1)

        let last = waypoints[waypoints.count - 1]
        #expect(last.position.z == 5.0, "Test Failed: Final retract Z mismatch")
    }

    @Test("Every engraving pass ramps from the depth the previous pass reached")
    func testEngravingRampStartsFromPreviousPass() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 3.175)
        let settings = rampTestSettings(targetDepth: -0.3, stepdown: 0.1)

        let toolpaths = try engine.generateToolpaths(from: [straightLine()],
                                                     tool: tool,
                                                     settings: settings,
                                                     operation: .engrave(entry: .ramp(angleDegrees: 2.0)))
        let passes = toolpaths[0].passes
        #expect(passes.count == 3)

        let expectedStart = [0.0, -0.1, -0.2]
        for (pass, startZ) in zip(passes, expectedStart) {
            #expect(pass.waypoints[1].position.z ~= startZ)
        }
    }

    @Test("A plain engrave keeps plunging")
    func testEngravingDefaultEntryIsPlunge() throws {
        let operation = SC.MachiningOperation.engrave()
        #expect(operation.entry == .plunge)
        #expect(operation == .engrave(entry: .plunge))
    }

    @Test("Engrave offers a plunge and a ramp, but no helix")
    func testEngravingRequirements() throws {
        let requirements = SC.MachiningOperation.engrave().requirements
        #expect(requirements.usesEntry)
        #expect(requirements.accepts(.plunge))
        #expect(requirements.accepts(.ramp(angleDegrees: 3.0)))
        #expect(!requirements.accepts(.helix(rampAngleDegrees: 2.0)))
        #expect(!requirements.accepts(.fromOpenEnd(stepoverPercentage: 0.4)))
    }

    @Test("Setting the entry on an engrave keeps it an engrave")
    func testEngravingEntryAccessor() throws {
        var operation = SC.MachiningOperation.engrave()
        operation.entry = .ramp(angleDegrees: 3.0)
        #expect(operation == .engrave(entry: .ramp(angleDegrees: 3.0)))
    }

    @Test("A helix entry is refused for an engrave")
    func testEngravingHelixIsRefused() throws {
        let tool = SC.ToolParams(diameter: 3.175)
        let operation = SC.MachiningOperation.engrave(entry: .helix(rampAngleDegrees: 2.0))

        #expect(throws: SC.Error.self) {
            try operation.validate(tool: tool)
        }
        #expect(throws: SC.Error.self) {
            try SCEngine().generateToolpaths(from: [straightLine()],
                                             tool: tool,
                                             settings: rampTestSettings(targetDepth: -0.1, stepdown: 0.1),
                                             operation: operation)
        }
    }
}
