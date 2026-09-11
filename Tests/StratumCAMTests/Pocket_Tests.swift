//
//  Pocket.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

struct Pocket_Tests {

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

    /// A 20x10 CCW rounded rectangle with 2mm corner radii.
    ///
    /// Start at (2,0), travel along the bottom edge, then use quarter-circle arcs
    /// at each corner. The resulting path is CCW.
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

    private func pocketStrategy(direction: SC.CutDirection) -> SC.Strategy {
        .pocket(direction: direction, pocketType: .offsetPattern, entry: .plunge)
    }

    // MARK: - Basic offset ring

    @Test("Pocket offsetPattern generates one inward ring for a rectangle")
    func testPocketRectangleGeneratesSingleInwardRing() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0, stepdown: 1.0)
        let settings = SC.MachineSettings(feedRate: 1000.0,
                                          plungeRate: 300.0,
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            strategy: pocketStrategy(direction: .climb)
        )

        #expect(toolpaths.count == 1, "Test Failed: expected 1 pocket toolpath")

        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 1,
                "Test Failed: Step 2.1 should generate exactly one Z pass")

        let firstPass = toolpath.passes[0]
        #expect(firstPass.depthZ == -1.0,
                "Test Failed: pocket depth mismatch")

        #expect(firstPass.waypoints.count == 7,
                "Test Failed: expected rapid, plunge, 4 ring vertices, retract")

        let box = bbox(firstPass.waypoints)

        // 20x10 rectangle, 3mm tool radius -> first inward ring is [3, 17] x [3, 7].
        #expect(abs(box.minX - 3.0) < 1e-5,
                "Test Failed: inward offset minX mismatch")

        #expect(abs(box.maxX - 17.0) < 1e-5,
                "Test Failed: inward offset maxX mismatch")

        #expect(abs(box.minY - 3.0) < 1e-5,
                "Test Failed: inward offset minY mismatch")

        #expect(abs(box.maxY - 7.0) < 1e-5,
                "Test Failed: inward offset maxY mismatch")
    }

    @Test("Pocket offsetPattern preserves rounded corners while offsetting inward")
    func testPocketRoundedRectangleGeneratesSingleInwardRing() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 3.0, stepdown: 1.0)
        let settings = SC.MachineSettings(feedRate: 1000.0,
                                          plungeRate: 300.0,
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [roundedRectangleContour()],
            tool: tool,
            settings: settings,
            strategy: pocketStrategy(direction: .climb)
        )

        #expect(toolpaths.count == 1,
                "Test Failed: expected 1 pocket toolpath")

        let waypoints = toolpaths[0].passes[0].waypoints
        let box = bbox(waypoints)

        // Original rounded rectangle is 20x10. A 1.5mm cutter radius moves the
        // boundary inward to [1.5, 18.5] x [1.5, 8.5]. Corner radius becomes 0.5mm.
        #expect(abs(box.minX - 1.5) < 1e-5,
                "Test Failed: rounded pocket minX mismatch")

        #expect(abs(box.maxX - 18.5) < 1e-5,
                "Test Failed: rounded pocket maxX mismatch")

        #expect(abs(box.minY - 1.5) < 1e-5,
                "Test Failed: rounded pocket minY mismatch")

        #expect(abs(box.maxY - 8.5) < 1e-5,
                "Test Failed: rounded pocket maxY mismatch")

        // The four original corner arcs remain arcs after offsetting, with their
        // radius reduced from 2.0mm to 0.5mm.
        let arcWaypoints = waypoints.filter { waypoint in
            if case .arcCCW = waypoint.motion {
                return true
            }

            if case .arcCW = waypoint.motion {
                return true
            }

            return false
        }

        #expect(arcWaypoints.count == 4,
                "Test Failed: expected four rounded-corner arc moves")
    }

    // MARK: - Direction

    @Test("Pocket honors climb versus conventional travel direction")
    func testPocketHonorsDirection() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0, stepdown: 1.0)
        let settings = SC.MachineSettings(feedRate: 1000.0,
                                          plungeRate: 300.0,
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let climb = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            strategy: pocketStrategy(direction: .climb)
        )[0].passes[0].waypoints

        let conventional = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            strategy: pocketStrategy(direction: .conventional)
        )[0].passes[0].waypoints

        // Both paths start at the same inward corner, but their traversal direction
        // is reversed because profile's direction helper is reused.
        let climbPlunge = climb[1]

        #expect(abs(climbPlunge.position.x - 3.0) < 1e-5 &&
                abs(climbPlunge.position.y - 3.0) < 1e-5,
                "Test Failed: climb pocket should start at the inward bottom-left corner")

        let conventionalPlunge = conventional[1]

        #expect(abs(conventionalPlunge.position.x - 3.0) < 1e-5 &&
                abs(conventionalPlunge.position.y - 3.0) < 1e-5,
                "Test Failed: conventional pocket should start at the inward bottom-left corner")

        let climbFirstCut = climb[2]

        #expect(abs(climbFirstCut.position.x - 3.0) < 1e-5 &&
                abs(climbFirstCut.position.y - 7.0) < 1e-5,
                "Test Failed: climb pocket should travel upward from the start corner")

        let conventionalFirstCut = conventional[2]

        #expect(abs(conventionalFirstCut.position.x - 17.0) < 1e-5 &&
                abs(conventionalFirstCut.position.y - 3.0) < 1e-5,
                "Test Failed: conventional pocket should travel rightward from the start corner")

        let climbBox = bbox(climb)
        let conventionalBox = bbox(conventional)

        #expect(abs(climbBox.minX - conventionalBox.minX) < 1e-5)
        #expect(abs(climbBox.maxX - conventionalBox.maxX) < 1e-5)
        #expect(abs(climbBox.minY - conventionalBox.minY) < 1e-5)
        #expect(abs(climbBox.maxY - conventionalBox.maxY) < 1e-5)
    }

    // MARK: - Validation

    @Test("An open contour does not produce a pocket toolpath")
    func testPocketRequiresClosedContour() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0, stepdown: 1.0)
        let settings = SC.MachineSettings(feedRate: 1000.0,
                                          plungeRate: 300.0,
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let openContour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0),
                                b: DXF.Point(10, 0),
                                layer: "0",
                                color: 7),
                  reversed: false),

            .init(entity: .line(a: DXF.Point(10, 0),
                                b: DXF.Point(10, 10),
                                layer: "0",
                                color: 7),
                  reversed: false)
        ], isClosed: false)

        let toolpaths = engine.generateToolpaths(
            from: [openContour],
            tool: tool,
            settings: settings,
            strategy: pocketStrategy(direction: .climb)
        )

        #expect(toolpaths.isEmpty,
                "Test Failed: open contours must not generate pocket toolpaths")
    }
}
