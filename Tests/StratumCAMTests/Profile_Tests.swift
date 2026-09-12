//
//  Profile_Tests.swift
//  StratumCAM
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

// Covers `.contour`: tool-radius offset direction (inside/outside), climb vs conventional
// travel reversal, each entry style (plunge/ramp/helix), and holding-tab depth clamping.

struct Profile_Tests {

    // MARK: - Fixtures

    /// A 10x10 CCW square: (0,0) -> (10,0) -> (10,10) -> (0,10) -> back to (0,0).
    private func ccwSquareSegments() -> [SC.Segment] {
        [
            .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 0)),
            .line(start: CGPoint(x: 10, y: 0), end: CGPoint(x: 10, y: 10)),
            .line(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 0, y: 10)),
            .line(start: CGPoint(x: 0, y: 10), end: CGPoint(x: 0, y: 0))
        ]
    }

    /// Same square as a closed `SC.Contour` for full-toolpath tests.
    private func ccwSquareContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(10, 0), b: DXF.Point(10, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(10, 10), b: DXF.Point(0, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, 10), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    /// A 20mm-long line split into 4 equal segments, so a tab centered mid-path lands
    /// exactly on a vertex instead of the middle of a single segment.
    private func fourSegmentLineContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(5, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(5, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(10, 0), b: DXF.Point(15, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(15, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
    }

    private func bbox(_ waypoints: [SC.Waypoint]) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let xs = waypoints.map { $0.position.x }
        let ys = waypoints.map { $0.position.y }
        return (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
    }

    // MARK: - Offset direction

    @Test("Outside profile offsets the toolpath away from the contour")
    func testProfileOutsideOffsetsAwayFromContour() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwSquareContour()], tool: tool, settings: settings,
            operation: .contour(side: .outside, direction: .climb, entry: .plunge, leadIn: nil, leadOut: nil, tabs: [])
        )

        #expect(toolpaths.count == 1)
        let box = bbox(toolpaths[0].passes[0].waypoints)

        // 10x10 square, 3mm tool radius -> outside toolpath bbox expands to [-3, 13] on both axes.
        #expect(abs(box.minX - (-3.0)) < 1e-5, "Test Failed: outside offset minX mismatch")
        #expect(abs(box.maxX - 13.0) < 1e-5, "Test Failed: outside offset maxX mismatch")
        #expect(abs(box.minY - (-3.0)) < 1e-5, "Test Failed: outside offset minY mismatch")
        #expect(abs(box.maxY - 13.0) < 1e-5, "Test Failed: outside offset maxY mismatch")
    }

    @Test("Inside profile offsets the toolpath toward the contour center")
    func testProfileInsideOffsetsTowardContourCenter() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwSquareContour()], tool: tool, settings: settings,
            operation: .contour(side: .inside, direction: .climb, entry: .plunge, leadIn: nil, leadOut: nil, tabs: [])
        )

        #expect(toolpaths.count == 1)
        let box = bbox(toolpaths[0].passes[0].waypoints)

        // 10x10 square, 3mm tool radius -> inside toolpath bbox shrinks to [3, 7] on both axes.
        #expect(abs(box.minX - 3.0) < 1e-5, "Test Failed: inside offset minX mismatch")
        #expect(abs(box.maxX - 7.0) < 1e-5, "Test Failed: inside offset maxX mismatch")
        #expect(abs(box.minY - 3.0) < 1e-5, "Test Failed: inside offset minY mismatch")
        #expect(abs(box.maxY - 7.0) < 1e-5, "Test Failed: inside offset maxY mismatch")
    }

    // MARK: - Climb vs conventional

    @Test("Outside profile with climb direction keeps the CCW winding unchanged")
    func testProfileOutsideClimbKeepsCCWWinding() {
        let engine = SCEngine()
        let square = ccwSquareSegments()

        let oriented = engine.orientedForDirection(square, side: .outside, direction: .climb)

        #expect(oriented.first == square.first, "Test Failed: climb+outside should not reorient an already-CCW contour")
    }

    @Test("Outside profile with conventional direction reverses travel to clockwise")
    func testProfileOutsideConventionalReversesToClockwise() {
        let engine = SCEngine()
        let square = ccwSquareSegments()

        let oriented = engine.orientedForDirection(square, side: .outside, direction: .conventional)

        guard case let .line(start, end) = oriented.first else {
            Issue.record("Test Failed: expected a line segment")
            return
        }
        #expect(start == CGPoint(x: 0, y: 0), "Test Failed: reversed start mismatch")
        #expect(end == CGPoint(x: 0, y: 10), "Test Failed: reversed end mismatch")
    }

    @Test("Inside profile with climb direction reverses travel to clockwise")
    func testProfileInsideClimbReversesToClockwise() {
        let engine = SCEngine()
        let square = ccwSquareSegments()

        // Inside cuts need the opposite winding from outside cuts for the same climb direction.
        let oriented = engine.orientedForDirection(square, side: .inside, direction: .climb)

        guard case let .line(start, end) = oriented.first else {
            Issue.record("Test Failed: expected a line segment")
            return
        }
        #expect(start == CGPoint(x: 0, y: 0), "Test Failed: reversed start mismatch")
        #expect(end == CGPoint(x: 0, y: 10), "Test Failed: reversed end mismatch")
    }

    // MARK: - Entry strategies

    @Test("Plunge entry starts directly on the offset contour's start point")
    func testProfilePlungeEntryStartsAtOffsetContourStart() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwSquareContour()], tool: tool, settings: settings,
            operation: .contour(side: .outside, direction: .climb, entry: .plunge, leadIn: nil, leadOut: nil, tabs: [])
        )

        let waypoints = toolpaths[0].passes[0].waypoints

        // [0] Rapid above the offset contour's start point (0, -3) @ SafeZ (5.0)
        // [1] Plunge to (0, -3) @ TargetZ (-1.0), no lead-in requested
        let wp0 = waypoints[0]
        #expect(abs(wp0.position.x - 0.0) < 1e-5 && abs(wp0.position.y - (-3.0)) < 1e-5 && wp0.position.z == 5.0,
                "Test Failed: initial rapid move incorrect")
        if case .rapid = wp0.motion {} else {
            Issue.record("Test Failed: first waypoint motion must be .rapid")
        }

        let wp1 = waypoints[1]
        #expect(abs(wp1.position.x - 0.0) < 1e-5 && abs(wp1.position.y - (-3.0)) < 1e-5, "Test Failed: plunge XY mismatch")
        #expect(wp1.position.z == -1.0, "Test Failed: plunge Z mismatch")
        #expect(wp1.feedRate == 300.0, "Test Failed: plunge feed rate should match settings")
    }

    @Test("Ramp entry descends gradually and lands back on the contour start at depth")
    func testProfileRampEntryDescendsGradually() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwSquareContour()], tool: tool, settings: settings,
            operation: .contour(side: .outside, direction: .climb, entry: .ramp(angleDegrees: 30), leadIn: nil, leadOut: nil, tabs: [])
        )

        let waypoints = toolpaths[0].passes[0].waypoints

        // [0] Rapid above the offset contour start (0, -3) @ SafeZ
        // [1] Ramp leg 1: across to (10, -3), dropping partway (Z = 2)
        // [2] Ramp leg 2: back to (0, -3), landing exactly at TargetZ (-1.0)
        #expect(waypoints.count >= 3)

        let wp0 = waypoints[0]
        #expect(abs(wp0.position.x - 0.0) < 1e-5 && abs(wp0.position.y - (-3.0)) < 1e-5 && wp0.position.z == 5.0,
                "Test Failed: initial rapid move incorrect")

        let wp1 = waypoints[1]
        #expect(abs(wp1.position.x - 10.0) < 1e-5 && abs(wp1.position.y - (-3.0)) < 1e-5, "Test Failed: ramp leg 1 XY mismatch")
        #expect(abs(wp1.position.z - 2.0) < 1e-9, "Test Failed: ramp leg 1 should be partway down, not at full depth")

        let wp2 = waypoints[2]
        #expect(abs(wp2.position.x - 0.0) < 1e-5 && abs(wp2.position.y - (-3.0)) < 1e-5, "Test Failed: ramp leg 2 XY mismatch")
        #expect(abs(wp2.position.z - (-1.0)) < 1e-9, "Test Failed: ramp should land exactly at target depth")
    }

    @Test("Helix entry spirals down and returns to the contour start at depth")
    func testProfileHelixEntryReturnsToContourStartAtDepth() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwSquareContour()], tool: tool, settings: settings,
            operation: .contour(side: .outside,
                                direction: .climb,
                                entry: .helix(radius: 2, rampAngleDegrees: 30),
                                leadIn: nil,
                                leadOut: nil,
                                tabs: [])
        )

        let waypoints = toolpaths[0].passes[0].waypoints

        let wp0 = waypoints[0]
        #expect(abs(wp0.position.x - 0.0) < 1e-5 && abs(wp0.position.y - (-3.0)) < 1e-5 && wp0.position.z == 5.0,
                "Test Failed: initial rapid move incorrect")

        // A helix always completes a whole number of turns, so somewhere in the entry
        // phase it must land back exactly on the offset contour's start point at target depth.
        let landsAtTarget = waypoints.contains { wp in
            abs(wp.position.x - 0.0) < 1e-6 && abs(wp.position.y - (-3.0)) < 1e-6 && abs(wp.position.z - (-1.0)) < 1e-6
        }
        #expect(landsAtTarget, "Test Failed: expected helix entry to land back on contour start at target depth")
    }

    // MARK: - Holding tabs

    @Test("A holding tab clamps depth locally without affecting the rest of the pass")
    func testProfileHoldingTabClampsDepthLocally() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 3.0), safeZ: 5.0, targetDepth: -3.0)
        let tab = SC.HoldingTab(positionRatio: 0.5, width: 2.0, height: 1.5)

        let toolpaths = engine.generateToolpaths(
            from: [fourSegmentLineContour()], tool: tool, settings: settings,
            operation: .contour(side: .onContour,
                                direction: .climb,
                                entry: .plunge,
                                leadIn: nil,
                                leadOut: nil,
                                tabs: [tab])
        )

        let waypoints = toolpaths[0].passes[0].waypoints

        // [0] Rapid @ SafeZ, [1] Plunge @ -3.0 (0,0)
        // [2] End of seg 1 (5,0) @ -3.0 -- full depth, outside the tab span
        // [3] End of seg 2 (10,0) @ -1.5 -- tab center, clamped to its remaining-stock floor
        // [4] End of seg 3 (15,0) @ -3.0 -- full depth again, past the tab
        #expect(waypoints.count >= 5)

        let clamped = waypoints[3]
        #expect(abs(clamped.position.x - 10.0) < 1e-5, "Test Failed: expected the tab-clamped waypoint at x=10")
        #expect(abs(clamped.position.z - (-1.5)) < 1e-9, "Test Failed: tab should clamp Z to its remaining-stock floor (-1.5), not full depth")

        let unclampedBefore = waypoints[2]
        #expect(abs(unclampedBefore.position.z - (-3.0)) < 1e-9, "Test Failed: waypoint before the tab should still be at full depth")

        let unclampedAfter = waypoints[4]
        #expect(abs(unclampedAfter.position.z - (-3.0)) < 1e-9, "Test Failed: waypoint after the tab should return to full depth")
    }
}
