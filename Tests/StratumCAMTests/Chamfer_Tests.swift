//
//  Chamfer_Tests.swift
//  StratumCAM
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

// Covers `.chamfer`: depth resolution from width+vAngle, explicit depth override,
// tool-validation failure, inside/outside offset direction, and climb/conventional travel.

struct Chamfer_Tests {

    // MARK: - Fixtures

    /// A 10x10 CCW square: (0,0) -> (10,0) -> (10,10) -> (0,10) -> back to (0,0).
    private func ccwSquareContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(10, 0), b: DXF.Point(10, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(10, 10), b: DXF.Point(0, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, 10), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    private func bbox(_ waypoints: [SC.Waypoint]) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let xs = waypoints.map { $0.position.x }
        let ys = waypoints.map { $0.position.y }
        return (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
    }

    // MARK: - Depth resolution

    @Test("Chamfer depth is derived from bevel width and the tool's V-bit angle")
    func testChamferDepthResolvedFromWidthAndVAngle() {
        let tool = SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 90.0)
        let params = SC.ChamferParams(width: 1.0, side: .outside, direction: .climb)

        // 90 deg included angle -> 45 deg half-angle -> tan(45) == 1 -> depth == -width
        let depth = params.resolvedDepth(for: tool)
        #expect(depth != nil)
        #expect(abs(depth! - (-1.0)) < 1e-9, "Test Failed: expected depth -1.0 for width 1.0 at a 90deg V-bit")
    }

    @Test("An explicit depth overrides the width/vAngle calculation")
    func testChamferExplicitDepthOverridesWidthCalculation() {
        // Use a flat end mill (not a V-bit) to prove the explicit depth bypasses the
        // V-bit requirement entirely, not just the width math.
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let params = SC.ChamferParams(width: 5.0, depth: 2.0, side: .outside, direction: .climb)

        let depth = params.resolvedDepth(for: tool)
        #expect(depth != nil)
        #expect(depth == -2.0, "Test Failed: explicit depth should be used as-is (sign-normalized), ignoring width/vAngle")
    }

    // MARK: - Tool validation

    @Test("A non-V-bit tool with no explicit depth resolves to nil and produces no toolpath")
    func testChamferNonVBitToolReturnsNil() throws {
        let params = SC.ChamferParams(width: 1.0, side: .outside, direction: .climb)

        // Direct resolution check.
        let flatTool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        #expect(params.resolvedDepth(for: flatTool) == nil, "Test Failed: expected nil depth for a non-V-bit tool")

        // Full pipeline should bail out cleanly rather than cut at a made-up depth.
        let engine = SCEngine()
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -1.0)
        let toolpaths = try engine.generateToolpaths(
            from: [ccwSquareContour()], tool: flatTool, settings: settings,
            operation: .chamfer(params: params)
        )
        #expect(toolpaths.isEmpty, "Test Failed: expected no toolpath for a misconfigured chamfer tool")
    }

    // MARK: - Offset direction

    @Test("Outside chamfer offsets the bevel away from the contour")
    func testChamferOutsideOffsetsAwayFromContour() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 90.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -1.0)
        let params = SC.ChamferParams(width: 1.0, side: .outside, direction: .climb)

        let toolpaths = try engine.generateToolpaths(from: [ccwSquareContour()],
                                                 tool: tool,
                                                 settings: settings,
                                                 operation: .chamfer(params: params))
        #expect(toolpaths.count == 1)
        let box = bbox(toolpaths[0].passes[0].waypoints)

        // width 1.0 at 90deg -> horizontal reach 1.0 -> bbox expands to [-1, 11] on both axes.
        #expect(abs(box.minX - (-1.0)) < 1e-5, "Test Failed: outside chamfer minX mismatch")
        #expect(abs(box.maxX - 11.0) < 1e-5, "Test Failed: outside chamfer maxX mismatch")
        #expect(abs(box.minY - (-1.0)) < 1e-5, "Test Failed: outside chamfer minY mismatch")
        #expect(abs(box.maxY - 11.0) < 1e-5, "Test Failed: outside chamfer maxY mismatch")
    }

    @Test("Inside chamfer offsets the bevel toward the contour center")
    func testChamferInsideOffsetsTowardContourCenter() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 90.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -1.0)
        let params = SC.ChamferParams(width: 1.0, side: .inside, direction: .climb)

        let toolpaths = try engine.generateToolpaths(from: [ccwSquareContour()], tool: tool, settings: settings, operation: .chamfer(params: params))
        #expect(toolpaths.count == 1)
        let box = bbox(toolpaths[0].passes[0].waypoints)

        // width 1.0 at 90deg -> horizontal reach 1.0 -> bbox shrinks to [1, 9] on both axes.
        #expect(abs(box.minX - 1.0) < 1e-5, "Test Failed: inside chamfer minX mismatch")
        #expect(abs(box.maxX - 9.0) < 1e-5, "Test Failed: inside chamfer maxX mismatch")
        #expect(abs(box.minY - 1.0) < 1e-5, "Test Failed: inside chamfer minY mismatch")
        #expect(abs(box.maxY - 9.0) < 1e-5, "Test Failed: inside chamfer maxY mismatch")
    }

    // MARK: - Direction (locks in the Step 0.1 fix)

    @Test("Chamfer honors climb vs conventional direction")
    func testChamferHonorsDirection() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 90.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -1.0)

        let climbParams = SC.ChamferParams(width: 1.0, side: .outside, direction: .climb)
        let conventionalParams = SC.ChamferParams(width: 1.0, side: .outside, direction: .conventional)

        let climbWaypoints = try engine.generateToolpaths(from: [ccwSquareContour()], tool: tool, settings: settings, operation: .chamfer(params: climbParams))[0].passes[0].waypoints
        let conventionalWaypoints = try engine.generateToolpaths(from: [ccwSquareContour()], tool: tool, settings: settings, operation: .chamfer(params: conventionalParams))[0].passes[0].waypoints

        // Climb (already-CCW square, no reorientation needed) starts its cut below the
        // bottom edge, at (0, -1).
        let climbPlunge = climbWaypoints[1]
        #expect(abs(climbPlunge.position.x - 0.0) < 1e-5 && abs(climbPlunge.position.y - (-1.0)) < 1e-5,
                "Test Failed: climb chamfer should plunge at (0, -1)")

        // Conventional reverses the square to CW first, so the cut starts left of the
        // left edge instead, at (-1, 0).
        let conventionalPlunge = conventionalWaypoints[1]
        #expect(abs(conventionalPlunge.position.x - (-1.0)) < 1e-5 && abs(conventionalPlunge.position.y - 0.0) < 1e-5,
                "Test Failed: conventional chamfer should plunge at (-1, 0)")
    }

    @Test("Chamfer honors climb vs conventional direction")
    func testChamferHonorsDirection_old() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 90.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -1.0)

        // CCW square
        let square = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(10, 0), b: DXF.Point(10, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(10, 10), b: DXF.Point(0, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, 10), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)

        let climbParams = SC.ChamferParams(width: 1.0, side: .outside, direction: .climb)
        let conventionalParams = SC.ChamferParams(width: 1.0, side: .outside, direction: .conventional)

        let climbPath = try engine.generateToolpaths(from: [square],
                                                 tool: tool,
                                                 settings: settings,
                                                 operation: .chamfer(params: climbParams)).first
        let conventionalPath = try engine.generateToolpaths(from: [square],
                                                        tool: tool,
                                                        settings: settings,
                                                        operation: .chamfer(params: conventionalParams)).first

        // Same geometry, opposite travel direction -> waypoint order should differ.
        #expect(climbPath?.passes.first?.waypoints != conventionalPath?.passes.first?.waypoints)
    }
}
