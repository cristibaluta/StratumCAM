//
//  Raster.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 12.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

// Step 1.1a: raster scanline geometry + clipping. No entry integration and no Z
// stepdown yet (Steps 1.2 / 1.3) -- these all check a single plunge-straight-down pass.

struct Raster_Tests {

    // MARK: - Fixtures

    /// A 20x10 CCW rectangle.
    private func ccwRectangleContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 0), b: DXF.Point(20, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 10), b: DXF.Point(0, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, 10), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    /// A 20x10 CCW rounded rectangle with 2mm corner radii -- same fixture as
    /// `Pocket_Tests`, reused here to prove scanlines clip against the true arc
    /// sweep rather than just the contour's overall bounding box.
    private func roundedRectangleContour() -> SC.Contour {
        let r = 2.0

        return SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(2, 0), b: DXF.Point(18, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .arc(center: DXF.Point(18, 2), radius: r, startDeg: -90, endDeg: 0, layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 2), b: DXF.Point(20, 8), layer: "0", color: 7), reversed: false),
            .init(entity: .arc(center: DXF.Point(18, 8), radius: r, startDeg: 0, endDeg: 90, layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(18, 10), b: DXF.Point(2, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .arc(center: DXF.Point(2, 8), radius: r, startDeg: 90, endDeg: 180, layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, 8), b: DXF.Point(0, 2), layer: "0", color: 7), reversed: false),
            .init(entity: .arc(center: DXF.Point(2, 2), radius: r, startDeg: 180, endDeg: 270, layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    private func bbox(_ waypoints: [SC.Waypoint]) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let xs = waypoints.map { $0.position.x }
        let ys = waypoints.map { $0.position.y }
        return (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
    }

    private func rasterStrategy(direction: SC.CutDirection) -> SC.MachiningOperation {
        .pocket(direction: direction, pocketType: .raster, entry: .plunge)
    }

    // MARK: - Scanline generation + stepover

    @Test("Raster covers a rectangle with parallel scanlines spaced by stepover")
    func testRasterCoversRectangleWithHonoredStepover() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                  plungeRate: 300.0,
                                                                  stepdown: 1.0,
                                                                  stepoverPercentage: 0.5),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: rasterStrategy(direction: .climb)
        )

        #expect(toolpaths.count == 1, "Test Failed: expected 1 raster toolpath")

        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 1,
                "Test Failed: Step 1.1 should generate exactly one Z pass")

        let waypoints = toolpath.passes[0].waypoints

        // 20x10 rectangle, 2mm tool radius -> wall offset is [2,18]x[2,8] (6mm tall).
        // 2mm stepover -> 4 rows (y=2,4,6,8) + 3 connecting transitions between them.
        // rapid + plunge + (4 rows + 3 connectors) + retract.
        #expect(waypoints.count == 10,
                "Test Failed: expected 10 waypoints for a 4-row raster pass, got \(waypoints.count)")

        #expect(waypoints[0].position.z == 5.0, "Test Failed: expected the initial rapid at safeZ")
        #expect(waypoints[1].position.z == -1.0, "Test Failed: expected a single plunge to targetDepth")

        // Climb starts the bottom row at the wall offset's bottom-left corner.
        #expect(abs(waypoints[1].position.x - 2.0) < 1e-5 && abs(waypoints[1].position.y - 2.0) < 1e-5,
                "Test Failed: expected the first plunge at (2, 2)")

        let box = bbox(waypoints)
        #expect(abs(box.minX - 2.0) < 1e-5 && abs(box.maxX - 18.0) < 1e-5,
                "Test Failed: raster X bounds should match the tool-radius wall offset")
        #expect(abs(box.minY - 2.0) < 1e-5 && abs(box.maxY - 8.0) < 1e-5,
                "Test Failed: raster Y bounds should match the tool-radius wall offset")

        #expect(waypoints[9].position.z == 5.0, "Test Failed: expected the final retract to safeZ")
    }

    // MARK: - Direction

    @Test("Raster honors climb versus conventional starting direction")
    func testRasterHonorsDirection() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                  plungeRate: 300.0,
                                                                  stepdown: 1.0,
                                                                  stepoverPercentage: 0.5),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let climb = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: rasterStrategy(direction: .climb)
        )[0].passes[0].waypoints

        let conventional = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: rasterStrategy(direction: .conventional)
        )[0].passes[0].waypoints

        // Both start the bottom row at the same Y, but climb sweeps left-to-right
        // while conventional sweeps right-to-left.
        let climbPlunge = climb[1]
        #expect(abs(climbPlunge.position.x - 2.0) < 1e-5 && abs(climbPlunge.position.y - 2.0) < 1e-5,
                "Test Failed: climb raster should start at the bottom-left corner")

        let climbFirstCut = climb[2]
        #expect(abs(climbFirstCut.position.x - 18.0) < 1e-5 && abs(climbFirstCut.position.y - 2.0) < 1e-5,
                "Test Failed: climb raster's first row should travel left-to-right")

        let conventionalPlunge = conventional[1]
        #expect(abs(conventionalPlunge.position.x - 18.0) < 1e-5 && abs(conventionalPlunge.position.y - 2.0) < 1e-5,
                "Test Failed: conventional raster should start at the bottom-right corner")

        let conventionalFirstCut = conventional[2]
        #expect(abs(conventionalFirstCut.position.x - 2.0) < 1e-5 && abs(conventionalFirstCut.position.y - 2.0) < 1e-5,
                "Test Failed: conventional raster's first row should travel right-to-left")

        // Same coverage either way -- direction only changes travel order, not area.
        let climbBox = bbox(climb)
        let conventionalBox = bbox(conventional)
        #expect(abs(climbBox.minX - conventionalBox.minX) < 1e-5)
        #expect(abs(climbBox.maxX - conventionalBox.maxX) < 1e-5)
        #expect(abs(climbBox.minY - conventionalBox.minY) < 1e-5)
        #expect(abs(climbBox.maxY - conventionalBox.maxY) < 1e-5)
    }

    // MARK: - Arc-bounded clipping

    @Test("Raster clips scanlines to the true arc sweep, not just the bounding box")
    func testRasterClipsAgainstRoundedContour() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                  plungeRate: 300.0,
                                                                  stepdown: 1.0,
                                                                  stepoverPercentage: 0.5),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [roundedRectangleContour()],
            tool: tool,
            settings: settings,
            operation: rasterStrategy(direction: .climb)
        )

        #expect(toolpaths.count == 1, "Test Failed: expected 1 raster toolpath")

        let waypoints = toolpaths[0].passes[0].waypoints

        // 1.5mm tool radius offset: straight edges move to x=[1.5,18.5]/y=[1.5,8.5],
        // corner arc radius shrinks from 2.0 to 0.5. Span 7.0 / 1.5mm stepover -> 6 rows
        // at y = 1.5, 3.0, 4.5, 6.0, 7.5, 8.5. rapid + plunge + (6 rows + 5 connectors) + retract.
        #expect(waypoints.count == 14,
                "Test Failed: expected 14 waypoints for a 6-row raster pass, got \(waypoints.count)")

        // The bottom row (y=1.5) sits exactly on the corner arcs' tangent points --
        // narrower than the straight-edge rows above it, because the rounded corners
        // cut the bottom row's ends inward. If clipping used the plain bounding box
        // instead of the actual arc sweep, this row would incorrectly span [1.5,18.5]
        // like the middle rows do.
        let bottomRowStart = waypoints[1]
        let bottomRowEnd = waypoints[2]
        #expect(abs(bottomRowStart.position.y - 1.5) < 1e-5, "Test Failed: expected the bottom row at y=1.5")
        #expect(abs(bottomRowStart.position.x - 2.0) < 1e-5,
                "Test Failed: bottom row should start at x=2.0 (the corner arc's tangent point), not the bbox edge at 1.5")
        #expect(abs(bottomRowEnd.position.x - 18.0) < 1e-5,
                "Test Failed: bottom row should end at x=18.0 (the corner arc's tangent point), not the bbox edge at 18.5")

        // A middle row (y=4.5) sits between the corner arcs entirely, so it spans the
        // full straight-edge width.
        let middleRowEnd = waypoints[6]
        #expect(abs(middleRowEnd.position.y - 4.5) < 1e-5, "Test Failed: expected a middle row at y=4.5")
        #expect(abs(middleRowEnd.position.x - 18.5) < 1e-5,
                "Test Failed: middle row should reach the full straight-edge width at x=18.5")

        // The top row (y=8.5) is narrowed by the top corner arcs the same way the
        // bottom row is.
        let topRowEnd = waypoints[12]
        #expect(abs(topRowEnd.position.y - 8.5) < 1e-5, "Test Failed: expected the top row at y=8.5")
        #expect(abs(topRowEnd.position.x - 2.0) < 1e-5,
                "Test Failed: top row should end at x=2.0 (the corner arc's tangent point), not the bbox edge at 1.5")
    }

    // MARK: - Validation

    @Test("An open contour does not produce a raster toolpath")
    func testRasterRequiresClosedContour() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                  plungeRate: 300.0,
                                                                  stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let openContour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(10, 0), b: DXF.Point(10, 10), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = engine.generateToolpaths(
            from: [openContour],
            tool: tool,
            settings: settings,
            operation: rasterStrategy(direction: .climb)
        )

        #expect(toolpaths.isEmpty,
                "Test Failed: open contours must not generate raster toolpaths")
    }
}
