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

// `.facing` sweeps the bounding box of whatever contour is passed in -- typically
// the finished part's own shape, not the raw stock block -- and goes through the
// same per-contour `generateToolpaths(from:tool:settings:operation:)` pipeline
// every other operation uses.

struct Facing_Tests {

    // MARK: - Fixtures

    /// A 20x10 CCW rectangle at the origin.
    private func rectangleContour(width: Double = 20, height: Double = 10, originX: Double = 0, originY: Double = 0) -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(originX, originY), b: DXF.Point(originX + width, originY), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(originX + width, originY), b: DXF.Point(originX + width, originY + height), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(originX + width, originY + height), b: DXF.Point(originX, originY + height), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(originX, originY + height), b: DXF.Point(originX, originY), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    // MARK: - Footprint

    @Test("Facing area grows the contour's bounding box by extensionLength on every side")
    func testFacingAreaExpandsBoundingBoxByExtensionLength() {
        let engine = SCEngine()
        let contour = rectangleContour(width: 100, height: 50)

        let area = engine.facingArea(for: contour, extensionLength: 5)

        #expect(area?.minX == -5, "Test Failed: expected minX grown 5mm past the contour's left edge")
        #expect(area?.maxX == 105, "Test Failed: expected maxX grown 5mm past the contour's right edge")
        #expect(area?.minY == -5, "Test Failed: expected minY grown 5mm past the contour's bottom edge")
        #expect(area?.maxY == 55, "Test Failed: expected maxY grown 5mm past the contour's top edge")
    }

    @Test("Facing area honors a contour placed away from the origin")
    func testFacingAreaHonorsContourOrigin() {
        let engine = SCEngine()
        let contour = rectangleContour(width: 40, height: 20, originX: 10, originY: 20)

        let area = engine.facingArea(for: contour, extensionLength: 2)

        #expect(area?.minX == 8, "Test Failed: expected minX offset by the contour's own position")
        #expect(area?.maxX == 52, "Test Failed: expected maxX offset by the contour's own position")
        #expect(area?.minY == 18, "Test Failed: expected minY offset by the contour's own position")
        #expect(area?.maxY == 42, "Test Failed: expected maxY offset by the contour's own position")
    }

    @Test("Facing area with zero extensionLength matches the contour's bounding box exactly")
    func testFacingAreaWithNoExtension() {
        let engine = SCEngine()
        let contour = rectangleContour(width: 30, height: 15)

        let area = engine.facingArea(for: contour, extensionLength: 0)

        #expect(area?.minX == 0 && area?.maxX == 30, "Test Failed: expected X bounds to match the contour exactly")
        #expect(area?.minY == 0 && area?.maxY == 15, "Test Failed: expected Y bounds to match the contour exactly")
    }

    // MARK: - Scanline generation + stepover

    @Test("Facing scanlines cover the footprint with parallel rows spaced by the tool-derived stepover")
    func testFacingScanlinesCoverFootprintWithHonoredStepover() {
        let engine = SCEngine()
        let contour = rectangleContour(width: 20, height: 10)
        // 9mm diameter -> 8.1mm stepover (90% engagement) over a 10mm-tall footprint
        // rounds up to 2 steps -> 3 rows.
        let tool = SC.ToolParams(diameter: 9)

        let rows = engine.facingScanlines(within: contour, extensionLength: 0, tool: tool, direction: .climb)

        #expect(rows.count == 3, "Test Failed: expected 3 rows, got \(rows.count)")
        #expect(abs(rows.first![0].startPoint.y - 0.0) < 1e-5, "Test Failed: expected the first row to sit exactly on the footprint's near edge")
        #expect(abs(rows.last![0].startPoint.y - 10.0) < 1e-5, "Test Failed: expected the last row to sit exactly on the footprint's far edge")

        for row in rows {
            let xs = [row[0].startPoint.x, row[0].endPoint.x].sorted()
            #expect(abs(xs[0] - 0.0) < 1e-5 && abs(xs[1] - 20.0) < 1e-5,
                    "Test Failed: expected every row to span the full footprint width [0,20]")
        }
    }

    @Test("Facing scanlines include extensionLength in both the row span and the row count")
    func testFacingScanlinesHonorExtensionLength() {
        let engine = SCEngine()
        let contour = rectangleContour(width: 20, height: 10)
        let tool = SC.ToolParams(diameter: 9)

        // 3mm extension -> footprint [-3,23]x[-3,13], a 16mm-tall span, vs. the
        // 10mm-tall span with no extension -- strictly more rows are needed to cover it.
        let baseRows = engine.facingScanlines(within: contour, extensionLength: 0, tool: tool, direction: .climb)
        let extendedRows = engine.facingScanlines(within: contour, extensionLength: 3.0, tool: tool, direction: .climb)

        #expect(extendedRows.count > baseRows.count,
                "Test Failed: expected extensionLength to require more rows to cover the taller span")

        for row in extendedRows {
            let xs = [row[0].startPoint.x, row[0].endPoint.x].sorted()
            #expect(abs(xs[0] - (-3.0)) < 1e-5 && abs(xs[1] - 23.0) < 1e-5,
                    "Test Failed: expected every row to span the extended footprint width [-3,23]")
        }
        #expect(abs(extendedRows.first![0].startPoint.y - (-3.0)) < 1e-5,
                "Test Failed: expected the first row to sit on the extended footprint's near edge")
        #expect(abs(extendedRows.last![0].startPoint.y - 13.0) < 1e-5,
                "Test Failed: expected the last row to sit on the extended footprint's far edge")
    }

    // MARK: - Direction

    @Test("Facing scanlines honor climb versus conventional starting direction")
    func testFacingScanlinesHonorDirection() {
        let engine = SCEngine()
        let contour = rectangleContour(width: 20, height: 10)
        let tool = SC.ToolParams(diameter: 9)

        let climbRows = engine.facingScanlines(within: contour, extensionLength: 0, tool: tool, direction: .climb)
        let conventionalRows = engine.facingScanlines(within: contour, extensionLength: 0, tool: tool, direction: .conventional)

        #expect(climbRows.count == conventionalRows.count,
                "Test Failed: direction should not change how many rows are generated")

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
        let contour = rectangleContour(width: 20, height: 10)
        let tool = SC.ToolParams(diameter: 4)

        let rows = engine.facingScanlines(within: contour, extensionLength: 0, tool: tool, direction: .climb)

        for (i, row) in rows.enumerated() {
            let travelsLeftToRight = row[0].startPoint.x < row[0].endPoint.x
            #expect(travelsLeftToRight == (i % 2 == 0),
                    "Test Failed: expected row \(i) to alternate direction from its neighbors")
        }
    }

    // MARK: - Validation

    @Test("Facing scanlines are empty for a degenerate (zero-area) contour")
    func testFacingScanlinesRequireNonZeroArea() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6)
        // A single line has zero height -- a degenerate bounding box, not a real footprint.
        let degenerateContour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        #expect(engine.facingScanlines(within: degenerateContour, extensionLength: 0, tool: tool, direction: .climb).isEmpty,
                "Test Failed: a zero-height bounding box should produce no scanlines")
    }

    // MARK: - Toolpath + direction

    @Test("Facing produces a single pass at target depth, rows chained into one continuous trace")
    func testFacingToolpathIsSinglePassAtTargetDepth() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 9.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: 0.5)
        let contour = rectangleContour(width: 20, height: 10)

        let toolpaths = try! engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                       operation: .facing(direction: .climb, extensionLength: 0))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 1, "Test Failed: facing is a one-pass datum operation")
        #expect(toolpath.passes[0].depthZ == -0.5, "Test Failed: expected depth to be -abs(targetDepth)")

        // 3 rows -> rapid, plunge, then 3 row-ends (2 joined by a connecting move
        // rather than a second rapid/plunge), then a final retract.
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

    @Test("Facing footprint includes extensionLength, wired end to end through the toolpath")
    func testFacingToolpathHonorsExtensionLength() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(), safeZ: 5.0, targetDepth: 1.0)
        let contour = rectangleContour(width: 20, height: 10)

        let toolpath = try! engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                      operation: .facing(direction: .climb, extensionLength: 4.0))[0]

        let xs = toolpath.passes[0].waypoints.map { $0.position.x }
        let ys = toolpath.passes[0].waypoints.map { $0.position.y }

        #expect(abs(xs.min()! - (-4.0)) < 1e-9, "Test Failed: expected the toolpath to reach past the contour by extensionLength on -X")
        #expect(abs(xs.max()! - 24.0) < 1e-9, "Test Failed: expected the toolpath to reach past the contour by extensionLength on +X")
        #expect(abs(ys.min()! - (-4.0)) < 1e-9, "Test Failed: expected the toolpath to reach past the contour by extensionLength on -Y")
        #expect(abs(ys.max()! - 14.0) < 1e-9, "Test Failed: expected the toolpath to reach past the contour by extensionLength on +Y")
    }

    @Test("Facing only sweeps the passed-in contour's own shape, not an unrelated larger stock")
    func testFacingSweepsOnlyThePassedContour() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(), safeZ: 5.0, targetDepth: 1.0)
        // A small 10x10 part shape, as if it sat in the corner of a much bigger sheet
        // of stock -- facing should only cover this shape's own footprint.
        let partContour = rectangleContour(width: 10, height: 10)

        let toolpath = try! engine.generateToolpaths(from: [partContour], tool: tool, settings: settings,
                                                      operation: .facing(direction: .climb, extensionLength: 0))[0]

        let xs = toolpath.passes[0].waypoints.map { $0.position.x }
        let ys = toolpath.passes[0].waypoints.map { $0.position.y }

        #expect(xs.max()! <= 10.0 + 1e-9, "Test Failed: expected the toolpath to stay within the part shape's own width")
        #expect(ys.max()! <= 10.0 + 1e-9, "Test Failed: expected the toolpath to stay within the part shape's own height")
    }

    @Test("A batch of contours produces one facing toolpath per contour, independent settings")
    func testFacingBatchProducesOneToolpathPerContour() {
        let engine = SCEngine()
        let smallTool = SC.ToolParams(diameter: 6.0)
        let bigTool = SC.ToolParams(diameter: 10.0)
        let settingsA = SC.MachineSettings(cutting: SC.CuttingData(), safeZ: 5.0, targetDepth: 0.5)

        let contours = [rectangleContour(width: 20, height: 10), rectangleContour(width: 30, height: 15, originX: 30)]

        let toolpaths = try! engine.generateToolpaths(from: contours, tool: smallTool, settings: settingsA,
                                                       operation: .facing(direction: .climb, extensionLength: 0))

        #expect(toolpaths.count == 2, "Test Failed: expected one output toolpath per contour")
        #expect(toolpaths[0].tool == smallTool && toolpaths[1].tool == smallTool,
                "Test Failed: a single generateToolpaths call shares one tool across its contours")
        _ = bigTool // kept for parity with other batch tests exercising a second tool elsewhere
    }

    @Test("A degenerate (zero-area) contour throws invalidContour")
    func testFacingRequiresNonZeroArea() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0),
                                          safeZ: 5.0, targetDepth: 0.5)
        let degenerateContour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        do {
            _ = try engine.generateToolpaths(from: [degenerateContour], tool: tool, settings: settings,
                                             operation: .facing(direction: .climb, extensionLength: 0))
            Issue.record("Test Failed: expected SC.Error.invalidContour to be thrown")
        } catch SC.Error.invalidContour {
            // expected
        } catch {
            Issue.record("Test Failed: expected SC.Error.invalidContour, got \(error)")
        }
    }

    @Test("An extensionLength negative enough to collapse the footprint throws invalidContour")
    func testFacingCollapsedFootprintThrowsInvalidContour() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0),
                                          safeZ: 5.0, targetDepth: 0.5)
        // A valid, non-zero contour -- but an extensionLength negative enough that
        // `facingArea`'s grown rectangle collapses to zero (or negative) span.
        let contour = rectangleContour(width: 10, height: 10)

        do {
            _ = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                             operation: .facing(direction: .climb, extensionLength: -100))
            Issue.record("Test Failed: expected SC.Error.invalidContour to be thrown")
        } catch SC.Error.invalidContour {
            // expected
        } catch {
            Issue.record("Test Failed: expected SC.Error.invalidContour, got \(error)")
        }
    }
}
