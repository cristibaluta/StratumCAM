//
//  Facing_Tests.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

// Step 2A.1: facing footprint (`facingArea`) + raster scanline geometry
// (`facingScanlines`). Step 2A.2 (below): turning those scanlines into a real
// toolpath via `SC.FacingOperation` + `generateToolpaths(from operations:
// [SC.FacingOperation])`, since `.facing` clears a whole `Stock` footprint and
// has no selected contour to go through the per-contour `buildToolpath` switch.

struct Facing_Tests {

    // MARK: - Footprint

    @Test("Facing area grows the stock rectangle by extensionLength on every side")
    func testFacingAreaExpandsStockByExtensionLength() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 100, height: 50, thickness: 10, origin: .zero)

        let area = engine.facingArea(stock: stock, extensionLength: 5)

        #expect(area.minX == -5, "Test Failed: expected minX grown 5mm past the stock's left edge")
        #expect(area.maxX == 105, "Test Failed: expected maxX grown 5mm past the stock's right edge")
        #expect(area.minY == -5, "Test Failed: expected minY grown 5mm past the stock's bottom edge")
        #expect(area.maxY == 55, "Test Failed: expected maxY grown 5mm past the stock's top edge")
    }

    @Test("Facing area honors a non-zero stock origin")
    func testFacingAreaHonorsStockOrigin() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 40, height: 20, thickness: 6, origin: SIMD3<Double>(10, 20, 0))

        let area = engine.facingArea(stock: stock, extensionLength: 2)

        #expect(area.minX == 8, "Test Failed: expected minX offset by the stock's own origin")
        #expect(area.maxX == 52, "Test Failed: expected maxX offset by the stock's own origin")
        #expect(area.minY == 18, "Test Failed: expected minY offset by the stock's own origin")
        #expect(area.maxY == 42, "Test Failed: expected maxY offset by the stock's own origin")
    }

    @Test("Facing area with zero extensionLength matches the stock rectangle exactly")
    func testFacingAreaWithNoExtension() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 30, height: 15, thickness: 6, origin: .zero)

        let area = engine.facingArea(stock: stock, extensionLength: 0)

        #expect(area.minX == 0 && area.maxX == 30, "Test Failed: expected X bounds to match the stock exactly")
        #expect(area.minY == 0 && area.maxY == 15, "Test Failed: expected Y bounds to match the stock exactly")
    }

    // MARK: - Scanline generation + stepover

    @Test("Facing scanlines cover the footprint with parallel rows spaced by stepover")
    func testFacingScanlinesCoverFootprintWithHonoredStepover() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        // No extension -> footprint is exactly [0,20]x[0,10]. 2mm stepover over a
        // 10mm-tall footprint -> 5 evenly-spaced rows (y=0,2,4,6,8,10).
        let rows = engine.facingScanlines(stock: stock, extensionLength: 0, stepover: 2.0, direction: .climb)

        #expect(rows.count == 6, "Test Failed: expected 6 rows for a 10mm span at 2mm stepover, got \(rows.count)")

        let rowYs = rows.map { $0[0].startPoint.y }
        let expectedYs = [0.0, 2.0, 4.0, 6.0, 8.0, 10.0]
        for (actual, expected) in zip(rowYs, expectedYs) {
            #expect(abs(actual - expected) < 1e-5, "Test Failed: expected row at y=\(expected), got y=\(actual)")
        }

        for row in rows {
            let xs = [row[0].startPoint.x, row[0].endPoint.x].sorted()
            #expect(abs(xs[0] - 0.0) < 1e-5 && abs(xs[1] - 20.0) < 1e-5,
                    "Test Failed: expected every row to span the full footprint width [0,20]")
        }
    }

    @Test("Facing scanlines include extensionLength in both the row span and the row count")
    func testFacingScanlinesHonorExtensionLength() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        // 3mm extension -> footprint [-3,23]x[-3,13], a 16mm-tall span. 4mm stepover
        // -> 4 steps exactly -> 5 rows (y = -3, 1, 5, 9, 13).
        let rows = engine.facingScanlines(stock: stock, extensionLength: 3.0, stepover: 4.0, direction: .climb)

        #expect(rows.count == 5, "Test Failed: expected 5 rows for a 16mm span at 4mm stepover, got \(rows.count)")

        let rowYs = rows.map { $0[0].startPoint.y }
        let expectedYs = [-3.0, 1.0, 5.0, 9.0, 13.0]
        for (actual, expected) in zip(rowYs, expectedYs) {
            #expect(abs(actual - expected) < 1e-5, "Test Failed: expected row at y=\(expected), got y=\(actual)")
        }

        for row in rows {
            let xs = [row[0].startPoint.x, row[0].endPoint.x].sorted()
            #expect(abs(xs[0] - (-3.0)) < 1e-5 && abs(xs[1] - 23.0) < 1e-5,
                    "Test Failed: expected every row to span the extended footprint width [-3,23]")
        }
    }

    // MARK: - Direction

    @Test("Facing scanlines honor climb versus conventional starting direction")
    func testFacingScanlinesHonorDirection() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        let climbRows = engine.facingScanlines(stock: stock, extensionLength: 0, stepover: 5.0, direction: .climb)
        let conventionalRows = engine.facingScanlines(stock: stock, extensionLength: 0, stepover: 5.0, direction: .conventional)

        #expect(climbRows.count == conventionalRows.count,
                "Test Failed: direction should not change how many rows are generated")

        // Climb starts left-to-right; conventional starts right-to-left. Every row
        // still alternates (boustrophedon), so the two sequences are exact mirrors of
        // each other, row for row.
        for (climbRow, conventionalRow) in zip(climbRows, conventionalRows) {
            #expect(climbRow[0].startPoint == conventionalRow[0].endPoint,
                    "Test Failed: expected climb and conventional to traverse each row in opposite directions")
            #expect(climbRow[0].endPoint == conventionalRow[0].startPoint,
                    "Test Failed: expected climb and conventional to traverse each row in opposite directions")
        }

        #expect(climbRows[0][0].startPoint.x < climbRows[0][0].endPoint.x,
                "Test Failed: expected climb's first row to travel left-to-right")
        #expect(conventionalRows[0][0].startPoint.x > conventionalRows[0][0].endPoint.x,
                "Test Failed: expected conventional's first row to travel right-to-left")
    }

    @Test("Facing scanlines alternate direction row to row (boustrophedon)")
    func testFacingScanlinesAlternateDirection() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        let rows = engine.facingScanlines(stock: stock, extensionLength: 0, stepover: 2.5, direction: .climb)

        for (i, row) in rows.enumerated() {
            let travelsLeftToRight = row[0].startPoint.x < row[0].endPoint.x
            #expect(travelsLeftToRight == (i % 2 == 0),
                    "Test Failed: expected row \(i) to alternate direction from its neighbors")
        }
    }

    // MARK: - Fencepost: uneven stepover snaps the last row to the footprint edge

    @Test("Facing scanlines snap the last row to the footprint edge on an unevenly divisible stepover")
    func testFacingScanlinesSnapsLastRowOnUnevenStepover() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        // 10mm span at 3mm stepover doesn't divide evenly (10 / 3 = 3.33), so it
        // rounds up to 4 steps -> 5 rows, with the final gap narrower than the other
        // 3 (each exactly 3mm) -- the same fencepost rule `rasterScanlines` and
        // `calculateZPasses` already apply.
        let rows = engine.facingScanlines(stock: stock, extensionLength: 0, stepover: 3.0, direction: .climb)

        #expect(rows.count == 5, "Test Failed: expected 5 rows (3 even steps + 1 snapped remainder), got \(rows.count)")

        let rowYs = rows.map { $0[0].startPoint.y }
        let expectedYs = [0.0, 3.0, 6.0, 9.0, 10.0]
        for (actual, expected) in zip(rowYs, expectedYs) {
            #expect(abs(actual - expected) < 1e-5, "Test Failed: expected row at y=\(expected), got y=\(actual)")
        }

        let lastGap = rowYs[4] - rowYs[3]
        #expect(lastGap < 3.0 - 1e-5,
                "Test Failed: expected the final row's gap to be narrower than the honored stepover")
    }

    // MARK: - Validation

    @Test("Facing scanlines are empty for a degenerate (zero-area) stock")
    func testFacingScanlinesRequireNonZeroStock() {
        let engine = SCEngine()
        let zeroWidthStock = SC.Stock(width: 0, height: 10, thickness: 6, origin: .zero)
        let zeroHeightStock = SC.Stock(width: 20, height: 0, thickness: 6, origin: .zero)

        #expect(engine.facingScanlines(stock: zeroWidthStock, extensionLength: 0, stepover: 2.0, direction: .climb).isEmpty,
                "Test Failed: a zero-width stock should produce no scanlines")
        #expect(engine.facingScanlines(stock: zeroHeightStock, extensionLength: 0, stepover: 2.0, direction: .climb).isEmpty,
                "Test Failed: a zero-height stock should produce no scanlines")
    }

    @Test("Facing scanlines are empty for a non-positive stepover")
    func testFacingScanlinesRequirePositiveStepover() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        #expect(engine.facingScanlines(stock: stock, extensionLength: 0, stepover: 0, direction: .climb).isEmpty,
                "Test Failed: a zero stepover should produce no scanlines")
        #expect(engine.facingScanlines(stock: stock, extensionLength: 0, stepover: -1, direction: .climb).isEmpty,
                "Test Failed: a negative stepover should produce no scanlines")
    }

    // MARK: - Step 2A.2: toolpath + direction

    @Test("Facing produces a single pass at target depth, rows chained into one continuous trace")
    func testFacingToolpathIsSinglePassAtTargetDepth() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: 0.5)
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        let operation = SC.FacingOperation(stock: stock, tool: tool, settings: settings, stepover: 5.0, direction: .climb, extensionLength: 0)
        let toolpaths = engine.generateToolpaths(from: [operation])

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 1, "Test Failed: facing is a one-pass datum operation")
        #expect(toolpath.passes[0].depthZ == -0.5, "Test Failed: expected depth to be -abs(targetDepth)")

        // 3 rows (0, 5, 10) -> rapid, plunge, then 3 row-ends (2 of which are joined
        // by a connecting move rather than a second rapid/plunge), then a final
        // retract -- rapid, plunge, row1-end, connect, row2-end, connect, row3-end, retract.
        let waypoints = toolpath.passes[0].waypoints
        #expect(waypoints.count == 8, "Test Failed: expected rapid+plunge+3 rows(+2 connects)+retract, got \(waypoints.count)")

        if case .rapid = waypoints.first!.motion {} else {
            Issue.record("Test Failed: first waypoint motion must be .rapid")
        }
        #expect(waypoints.first!.position.z == 5.0, "Test Failed: initial rapid should be at Safe Z")

        if case .rapid = waypoints.last!.motion {} else {
            Issue.record("Test Failed: last waypoint motion must be .rapid")
        }
        #expect(waypoints.last!.position.z == 5.0, "Test Failed: final retract should be at Safe Z")

        for waypoint in waypoints[1..<(waypoints.count - 1)] {
            #expect(waypoint.position.z == -0.5, "Test Failed: every traced move should stay at target depth")
        }
    }

    @Test("Facing scanline order flips with direction, but the toolpath still covers the full footprint")
    func testFacingToolpathHonorsDirection() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(), safeZ: 4.0, targetDepth: 1.0)
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        let climbOp = SC.FacingOperation(stock: stock, tool: tool, settings: settings, stepover: 5.0, direction: .climb, extensionLength: 0)
        let conventionalOp = SC.FacingOperation(stock: stock, tool: tool, settings: settings, stepover: 5.0, direction: .conventional, extensionLength: 0)

        let climbWaypoints = engine.generateToolpaths(from: [climbOp])[0].passes[0].waypoints
        let conventionalWaypoints = engine.generateToolpaths(from: [conventionalOp])[0].passes[0].waypoints

        #expect(climbWaypoints.count == conventionalWaypoints.count,
                "Test Failed: direction should not change the waypoint count")

        // Climb's first row travels left-to-right (toward x=20); conventional's first
        // row travels right-to-left (toward x=0) -- the plunge (index 1) is at each
        // row's own start, so the first row's *end* (index 2) is where they diverge.
        #expect(climbWaypoints[2].position.x > climbWaypoints[1].position.x,
                "Test Failed: expected climb's first row to end past its start toward +X")
        #expect(conventionalWaypoints[2].position.x < conventionalWaypoints[1].position.x,
                "Test Failed: expected conventional's first row to end past its start toward -X")
    }

    @Test("Facing footprint includes extensionLength, wired end to end through the toolpath")
    func testFacingToolpathHonorsExtensionLength() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(), safeZ: 5.0, targetDepth: 1.0)
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        let operation = SC.FacingOperation(stock: stock, tool: tool, settings: settings, stepover: 5.0, direction: .climb, extensionLength: 4.0)
        let toolpath = engine.generateToolpaths(from: [operation])[0]

        let xs = toolpath.passes[0].waypoints.map { $0.position.x }
        let ys = toolpath.passes[0].waypoints.map { $0.position.y }

        #expect(abs(xs.min()! - (-4.0)) < 1e-9, "Test Failed: expected the toolpath to reach past the stock by extensionLength on -X")
        #expect(abs(xs.max()! - 24.0) < 1e-9, "Test Failed: expected the toolpath to reach past the stock by extensionLength on +X")
        #expect(abs(ys.min()! - (-4.0)) < 1e-9, "Test Failed: expected the toolpath to reach past the stock by extensionLength on -Y")
        #expect(abs(ys.max()! - 14.0) < 1e-9, "Test Failed: expected the toolpath to reach past the stock by extensionLength on +Y")
    }

    @Test("A degenerate (zero-area) stock produces no facing toolpath")
    func testFacingToolpathRequiresNonZeroStock() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(), safeZ: 5.0, targetDepth: 1.0)
        let zeroWidthStock = SC.Stock(width: 0, height: 10, thickness: 6, origin: .zero)

        let operation = SC.FacingOperation(stock: zeroWidthStock, tool: tool, settings: settings, stepover: 5.0, direction: .climb, extensionLength: 0)

        #expect(engine.generateToolpaths(from: [operation]).isEmpty,
                "Test Failed: a zero-area stock should produce no facing toolpath")
    }

    @Test("The per-contour switch does not produce a facing toolpath -- .facing must go through FacingOperation")
    func testFacingIsNotReachableThroughPerContourSwitch() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(), safeZ: 5.0, targetDepth: 1.0)

        let contour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = engine.generateToolpaths(from: [contour],
                                                 tool: tool,
                                                 settings: settings,
                                                 operation: .facing(stepover: 5.0, direction: .climb, extensionLength: 0))

        #expect(toolpaths.isEmpty,
                "Test Failed: .facing has no contour to act on through the per-contour path and should yield nothing there")
    }

    @Test("A batch of FacingOperations produces one toolpath per operation, independent settings")
    func testFacingBatchProducesOneToolpathPerOperation() {
        let engine = SCEngine()
        let smallTool = SC.ToolParams(diameter: 6.0)
        let bigTool = SC.ToolParams(diameter: 10.0)
        let settingsA = SC.MachineSettings(cutting: SC.CuttingData(), safeZ: 5.0, targetDepth: 0.5)
        let settingsB = SC.MachineSettings(cutting: SC.CuttingData(), safeZ: 8.0, targetDepth: 1.5)

        let operations = [
            SC.FacingOperation(stock: SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero),
                               tool: smallTool, settings: settingsA, stepover: 5.0, direction: .climb, extensionLength: 0),
            SC.FacingOperation(stock: SC.Stock(width: 30, height: 15, thickness: 6, origin: .zero),
                               tool: bigTool, settings: settingsB, stepover: 6.0, direction: .conventional, extensionLength: 2.0)
        ]

        let toolpaths = engine.generateToolpaths(from: operations)

        #expect(toolpaths.count == 2, "Test Failed: expected one output toolpath per FacingOperation")
        #expect(toolpaths[0].tool == smallTool, "Test Failed: first toolpath should use the first operation's tool")
        #expect(toolpaths[1].tool == bigTool, "Test Failed: second toolpath should use the second operation's tool")
        #expect(toolpaths[0].passes[0].depthZ == -0.5, "Test Failed: first toolpath depth mismatch")
        #expect(toolpaths[1].passes[0].depthZ == -1.5, "Test Failed: second toolpath depth mismatch")
        #expect(toolpaths[0].operation == .facing(stepover: 5.0, direction: .climb, extensionLength: 0),
                "Test Failed: first toolpath should carry its own facing parameters")
        #expect(toolpaths[1].operation == .facing(stepover: 6.0, direction: .conventional, extensionLength: 2.0),
                "Test Failed: second toolpath should carry its own facing parameters")
    }
}
