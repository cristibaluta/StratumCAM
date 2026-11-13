//
//  Chamfer_Tests.swift
//  StratumCAM
//

import Testing
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
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(10, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(10, 0), b: SIMD2<Double>(10, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(10, 10), b: SIMD2<Double>(0, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, 10), b: SIMD2<Double>(0, 0)), reversed: false)
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
        let params = SC.ChamferParams(width: 1.0, side: .outside, direction: .conventional)

        // 90 deg included angle -> 45 deg half-angle -> tan(45) == 1 -> depth == -width
        let depth = params.resolvedDepth(for: tool)
        #expect(depth != nil)
        #expect(depth! ~= -1.0, "Test Failed: expected depth -1.0 for width 1.0 at a 90deg V-bit")
    }

    @Test("An explicit depth overrides the width/vAngle calculation")
    func testChamferExplicitDepthOverridesWidthCalculation() {
        // Use a flat end mill (not a V-bit) to prove the explicit depth bypasses the
        // V-bit requirement entirely, not just the width math.
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let params = SC.ChamferParams(width: 5.0, depth: 2.0, side: .outside, direction: .conventional)

        let depth = params.resolvedDepth(for: tool)
        #expect(depth != nil)
        #expect(depth == -2.0, "Test Failed: explicit depth should be used as-is (sign-normalized), ignoring width/vAngle")
    }

    // MARK: - Tool validation

    // Step 6.3: this used to assert that a misconfigured chamfer tool silently produced
    // an empty toolpaths array. It now throws `SC.Error.toolIncompatible` instead --
    // same "propagate rather than swallow" change Step 6.2 made for drilling -- so the
    // test asserts the throw rather than an empty result.
    @Test("A non-V-bit tool with no explicit depth resolves to nil and throws toolIncompatible")
    func testChamferNonVBitToolThrowsToolIncompatible() {
        let params = SC.ChamferParams(width: 1.0, side: .outside, direction: .conventional)

        // Direct resolution check.
        let flatTool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        #expect(params.resolvedDepth(for: flatTool) == nil, "Test Failed: expected nil depth for a non-V-bit tool")

        // Full pipeline should bail out cleanly rather than cut at a made-up depth.
        let engine = SCEngine()
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, targetDepth: -1.0)

        // do/catch rather than #expect(throws:) -- matching Drilling_Tests.swift's own
        // note on why (the exact-value overload of #expect(throws:) isn't pinned across
        // Swift Testing releases in this package).
        do {
            _ = try engine.generateToolpaths(
                from: [ccwSquareContour()], tool: flatTool, settings: settings,
                operation: .chamfer(params: params)
            )
            Issue.record("Test Failed: expected SC.Error.toolIncompatible to be thrown")
        } catch SC.Error.toolIncompatible {
            // expected
        } catch {
            Issue.record("Test Failed: expected SC.Error.toolIncompatible, got \(error)")
        }
    }

    @Test("An empty contour throws invalidContour rather than producing no toolpath")
    func testChamferEmptyContourThrowsInvalidContour() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 90.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, targetDepth: -1.0)
        let params = SC.ChamferParams(width: 1.0, side: .outside, direction: .conventional)
        let emptyContour = SC.Contour(entities: [], isClosed: true)

        do {
            _ = try engine.generateToolpaths(from: [emptyContour], tool: tool, settings: settings, operation: .chamfer(params: params))
            Issue.record("Test Failed: expected SC.Error.invalidContour to be thrown")
        } catch SC.Error.invalidContour {
            // expected
        } catch {
            Issue.record("Test Failed: expected SC.Error.invalidContour, got \(error)")
        }
    }

    // MARK: - Offset direction

    @Test("Outside chamfer offsets the bevel away from the contour")
    func testChamferOutsideOffsetsAwayFromContour() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 90.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, targetDepth: -1.0)
        let params = SC.ChamferParams(width: 1.0, side: .outside, direction: .conventional)

        let toolpaths = try engine.generateToolpaths(from: [ccwSquareContour()],
                                                 tool: tool,
                                                 settings: settings,
                                                 operation: .chamfer(params: params))
        #expect(toolpaths.count == 1)
        let box = bbox(toolpaths[0].passes[0].waypoints)

        // width 1.0 at 90deg -> horizontal reach 1.0 -> bbox expands to [-1, 11] on both axes.
        #expect(box.minX ~= -1.0, "Test Failed: outside chamfer minX mismatch")
        #expect(box.maxX ~= 11.0, "Test Failed: outside chamfer maxX mismatch")
        #expect(box.minY ~= -1.0, "Test Failed: outside chamfer minY mismatch")
        #expect(box.maxY ~= 11.0, "Test Failed: outside chamfer maxY mismatch")
    }

    @Test("Inside chamfer offsets the bevel toward the contour center")
    func testChamferInsideOffsetsTowardContourCenter() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 90.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, targetDepth: -1.0)
        let params = SC.ChamferParams(width: 1.0, side: .inside, direction: .conventional)

        let toolpaths = try engine.generateToolpaths(from: [ccwSquareContour()], tool: tool, settings: settings, operation: .chamfer(params: params))
        #expect(toolpaths.count == 1)
        let box = bbox(toolpaths[0].passes[0].waypoints)

        // width 1.0 at 90deg -> horizontal reach 1.0 -> bbox shrinks to [1, 9] on both axes.
        #expect(box.minX ~= 1.0, "Test Failed: inside chamfer minX mismatch")
        #expect(box.maxX ~= 9.0, "Test Failed: inside chamfer maxX mismatch")
        #expect(box.minY ~= 1.0, "Test Failed: inside chamfer minY mismatch")
        #expect(box.maxY ~= 9.0, "Test Failed: inside chamfer maxY mismatch")
    }

    // MARK: - Direction (locks in the Step 0.1 fix)

    @Test("Chamfer honors climb vs conventional direction")
    func testChamferHonorsDirection() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 90.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, targetDepth: -1.0)

        let climbParams = SC.ChamferParams(width: 1.0, side: .outside, direction: .conventional)
        let conventionalParams = SC.ChamferParams(width: 1.0, side: .outside, direction: .climb)

        let climbWaypoints = try engine.generateToolpaths(from: [ccwSquareContour()], tool: tool, settings: settings, operation: .chamfer(params: climbParams))[0].passes[0].waypoints
        let conventionalWaypoints = try engine.generateToolpaths(from: [ccwSquareContour()], tool: tool, settings: settings, operation: .chamfer(params: conventionalParams))[0].passes[0].waypoints

        // Climb (already-CCW square, no reorientation needed) starts its cut below the
        // bottom edge, at (0, -1).
        let climbPlunge = climbWaypoints[1]
        #expect(climbPlunge.position.x ~= 0.0 && climbPlunge.position.y ~= -1.0,
                "Test Failed: climb chamfer should plunge at (0, -1)")

        // Conventional reverses the square to CW first, so the cut starts left of the
        // left edge instead, at (-1, 0).
        let conventionalPlunge = conventionalWaypoints[1]
        #expect(conventionalPlunge.position.x ~= -1.0 && conventionalPlunge.position.y ~= 0.0,
                "Test Failed: conventional chamfer should plunge at (-1, 0)")
    }

    @Test("Chamfer honors climb vs conventional direction")
    func testChamferHonorsDirection_old() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 90.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, targetDepth: -1.0)

        // CCW square
        let square = SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(10, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(10, 0), b: SIMD2<Double>(10, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(10, 10), b: SIMD2<Double>(0, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, 10), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true)

        let climbParams = SC.ChamferParams(width: 1.0, side: .outside, direction: .conventional)
        let conventionalParams = SC.ChamferParams(width: 1.0, side: .outside, direction: .climb)

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

    // MARK: - Tool geometry (tip width, flank height)

    @Test("A V-bit's flank height follows from diameter, tip width and angle")
    func testFlankHeight() {
        // 6mm, 90deg, sharp tip: radial 3, tan(45)=1 -> 3
        #expect(SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 90.0).flankHeight! ~= 3.0)
        // A 2mm tip flat leaves 2mm of radial flank -> 2
        #expect(SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 90.0, tipWidth: 2.0).flankHeight! ~= 2.0)
        // 60deg: radial 3 / tan(30)
        #expect(SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 60.0).flankHeight! ~= 3.0 / tan(30.0 * Double.pi / 180.0))
        // Not a V-bit
        #expect(SC.ToolParams(type: .flatEndMill, diameter: 6.0).flankHeight == nil)
    }

    @Test("Bevel depth follows the tool angle: equal to width only at 90 degrees")
    func testBevelDepthFollowsAngle() {
        let params = SC.ChamferParams(width: 1.0)
        let b90 = params.resolvedBevel(for: SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 90.0))!
        let b60 = params.resolvedBevel(for: SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 60.0))!
        #expect(b90.depth ~= 1.0)
        #expect(b60.depth ~= 1.0 / tan(30.0 * Double.pi / 180.0))
    }

    // MARK: - Edge reference (top / bottom) and Z

    private func tool90(tipWidth: Double = 0) -> SC.ToolParams {
        SC.ToolParams(type: .vBit, diameter: 6.0, vAngle: 90.0, tipWidth: tipWidth)
    }

    private func settings(stepdown: Double = 1.0) -> SC.MachineSettings {
        SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: stepdown, stepoverPercentage: 0.4), safeZ: 5.0, targetDepth: -1.0)
    }

    private func passes(_ params: SC.ChamferParams, tool: SC.ToolParams? = nil, stepdown: Double = 1.0) throws -> [SC.ToolpathPass] {
        try SCEngine().generateToolpaths(from: [ccwSquareContour()], tool: tool ?? tool90(),
                                         settings: settings(stepdown: stepdown),
                                         operation: .chamfer(params: params))[0].passes
    }

    @Test("Top edge: the bevel starts at the contour's Z and descends; tip ends one depth lower")
    func testTopEdgeStartsAtEdgeZ() throws {
        let p = try passes(SC.ChamferParams(width: 1.0, side: .outside, edge: .top, edgeZ: -2.0))
        #expect(p.count == 1)
        #expect(p[0].depthZ ~= -3.0, "Test Failed: top edge at Z -2 with depth 1 should put the tip at -3")
        let box = bbox(p[0].waypoints)
        #expect(box.minX ~= -1.0 && box.maxX ~= 11.0, "Test Failed: tool center should sit one bevel width outside the top edge")
    }

    @Test("Bottom edge: the tool tip sits ON the contour at the bevel's bottom, the bevel rises from there")
    func testBottomEdgeDefaultsToStockTop() throws {
        // Default edgeZ for a bottom edge is -depth, so the bevel's top lands at Z = 0.
        let p = try passes(SC.ChamferParams(width: 1.0, side: .outside, edge: .bottom))
        #expect(p.count == 1)
        #expect(p[0].depthZ ~= -1.0, "Test Failed: bottom edge at Z -1 (default) should put the tip at -1")
        let box = bbox(p[0].waypoints)
        #expect(box.minX ~= 0.0 && box.maxX ~= 10.0 && box.minY ~= 0.0 && box.maxY ~= 10.0,
                "Test Failed: with a sharp tip and no tip offset the tool center follows the contour itself")
    }

    @Test("Bottom edge with an explicit Z starts at that Z and ends one depth above it")
    func testBottomEdgeHonorsEdgeZ() throws {
        let p = try passes(SC.ChamferParams(width: 1.0, side: .outside, edge: .bottom, edgeZ: -5.0))
        #expect(p[0].depthZ ~= -5.0, "Test Failed: tip should be at the bottom edge's Z")
    }

    // MARK: - Tip offset and tip flat

    @Test("Tip offset moves the cut up the flank: tip goes lower, tool center moves further out")
    func testTipOffset() throws {
        let p = try passes(SC.ChamferParams(width: 1.0, side: .outside, edge: .top, tipOffset: 1.0))
        #expect(p[0].depthZ ~= -2.0, "Test Failed: tip should be tipOffset below the bevel's bottom")
        let box = bbox(p[0].waypoints)
        #expect(box.minX ~= -2.0 && box.maxX ~= 12.0, "Test Failed: flank radius grows by tipOffset, so the center moves out by it")
    }

    @Test("A tip flat widens the tool-center offset by half its width")
    func testTipFlatOffsetsToolCenter() throws {
        let p = try passes(SC.ChamferParams(width: 1.0, side: .outside, edge: .top), tool: tool90(tipWidth: 1.0))
        let box = bbox(p[0].waypoints)
        #expect(box.minX ~= -1.5 && box.maxX ~= 11.5, "Test Failed: expected width 1 + tipWidth/2 = 1.5 outside the contour")
    }

    // MARK: - Reach errors

    @Test("Tip offset plus bevel depth taller than the flank throws chamferExceedsToolReach")
    func testTipOffsetBeyondFlankThrows() {
        // Flank is 3mm tall; depth 1 + tipOffset 3 = 4.
        do {
            _ = try passes(SC.ChamferParams(width: 1.0, side: .outside, tipOffset: 3.0))
            Issue.record("Test Failed: expected chamferExceedsToolReach")
        } catch SC.Error.chamferExceedsToolReach(let required, let available) {
            #expect(required ~= 4.0 && available ~= 3.0)
        } catch {
            Issue.record("Test Failed: expected chamferExceedsToolReach, got \(error)")
        }
    }

    @Test("A bevel deeper than the flank throws chamferExceedsToolReach, also from validate(tool:)")
    func testBevelDeeperThanFlankThrows() {
        let params = SC.ChamferParams(width: 4.0, side: .outside)
        do {
            try SC.MachiningOperation.chamfer(params: params).validate(tool: tool90())
            Issue.record("Test Failed: expected chamferExceedsToolReach from validate")
        } catch SC.Error.chamferExceedsToolReach(let required, let available) {
            #expect(required ~= 4.0 && available ~= 3.0)
        } catch {
            Issue.record("Test Failed: expected chamferExceedsToolReach, got \(error)")
        }
    }

    @Test("A tip flat as wide as the tool is an invalid tool parameter")
    func testTipWidthMustBeSmallerThanDiameter() {
        do {
            _ = try passes(SC.ChamferParams(width: 1.0), tool: tool90(tipWidth: 6.0))
            Issue.record("Test Failed: expected invalidParameter")
        } catch SC.Error.invalidParameter(let name) {
            #expect(name == "tool.tipWidth")
        } catch {
            Issue.record("Test Failed: expected invalidParameter, got \(error)")
        }
    }

    // MARK: - Stepdown

    @Test("Top-edge bevel is cut in stepdown passes: Z changes, the XY path stays fixed")
    func testTopEdgeStepdownPasses() throws {
        let p = try passes(SC.ChamferParams(width: 1.0, side: .outside, edge: .top), stepdown: 0.5)
        #expect(p.count == 2)
        #expect(p[0].depthZ ~= -0.5 && p[1].depthZ ~= -1.0)
        for pass in p {
            let box = bbox(pass.waypoints)
            #expect(box.minX ~= -1.0 && box.maxX ~= 11.0, "Test Failed: every pass should run the same full-width-out path")
        }
        #expect(p[0].waypoints.map { [$0.position.x, $0.position.y] } == p[1].waypoints.map { [$0.position.x, $0.position.y] },
                "Test Failed: passes must differ only in Z")
    }

    @Test("Bottom-edge bevel: passes go from the top down and end on the edge, with the XY path fixed on the contour")
    func testBottomEdgeStepdownPasses() throws {
        let p = try passes(SC.ChamferParams(width: 1.0, side: .outside, edge: .bottom), stepdown: 0.5)
        #expect(p.count == 2)
        // Bevel runs Z -1 (the edge) ... 0 (stock top): tip passes at -0.5 then -1.
        #expect(p[0].depthZ ~= -0.5 && p[1].depthZ ~= -1.0, "Test Failed: expected passes from the top down, the last on the edge")
        for pass in p {
            let box = bbox(pass.waypoints)
            #expect(box.minX ~= 0.0 && box.maxX ~= 10.0, "Test Failed: sharp tip -> tool center on the contour in every pass")
        }
    }

    @Test("A bottom edge sits below the stock top; a top edge sits at it")
    func testContourZ() {
        let tool = tool90()
        #expect(SC.ChamferParams(width: 1.5, edge: .top).contourZ(for: tool)! ~= 0.0)
        #expect(SC.ChamferParams(width: 1.5, edge: .bottom).contourZ(for: tool)! ~= -1.5)
        #expect(SC.ChamferParams(width: 1.5, edge: .bottom, edgeZ: -4.0).contourZ(for: tool)! ~= -4.0)
    }
}
