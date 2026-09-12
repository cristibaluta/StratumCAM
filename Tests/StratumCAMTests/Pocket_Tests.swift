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

    private func segmentsBBox(_ segments: [SC.Segment]) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        var xs: [Double] = []
        var ys: [Double] = []
        for segment in segments {
            xs.append(segment.startPoint.x)
            xs.append(segment.endPoint.x)
            ys.append(segment.startPoint.y)
            ys.append(segment.endPoint.y)
        }
        return (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
    }

    private func pocketStrategy(direction: SC.CutDirection) -> SC.MachiningOperation {
        .pocket(direction: direction, pocketType: .offsetPattern, entry: .plunge)
    }

    // MARK: - Concentric ring stepping (Step 2.2)

    @Test("Pocket rings step inward by stepover and stop before the ring would invert")
    func testPocketRingsStepInwardAndStopAtCollapse() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0, stepdown: 1.0, stepoverPercentage: 0.5)

        let baseSegments = engine.linearize(contour: ccwRectangleContour())
        let oriented = engine.orientedForDirection(baseSegments, side: .inside, direction: .climb)

        let rings = engine.pocketRings(from: oriented, tool: tool)

        // 20x10 rectangle, 2mm tool radius, 2mm stepover: ring 0 is [2,18]x[2,8].
        // A third-ring attempt would offset the already-6mm-tall ring 1 down to a
        // height of -2 -- it must stop there rather than emit an inverted ring.
        #expect(rings.count == 2,
                "Test Failed: expected exactly 2 rings before the next stepover would invert the ring")

        let ring0Box = segmentsBBox(rings[0])
        #expect(abs(ring0Box.minX - 2.0) < 1e-5 && abs(ring0Box.maxX - 18.0) < 1e-5,
                "Test Failed: ring 0 X bounds mismatch")
        #expect(abs(ring0Box.minY - 2.0) < 1e-5 && abs(ring0Box.maxY - 8.0) < 1e-5,
                "Test Failed: ring 0 Y bounds mismatch")

        let ring1Box = segmentsBBox(rings[1])
        #expect(abs(ring1Box.minX - 4.0) < 1e-5 && abs(ring1Box.maxX - 16.0) < 1e-5,
                "Test Failed: ring 1 X bounds mismatch -- stepover not honored")
        #expect(abs(ring1Box.minY - 4.0) < 1e-5 && abs(ring1Box.maxY - 6.0) < 1e-5,
                "Test Failed: ring 1 Y bounds mismatch -- stepover not honored")
    }

    @Test("Pocket chains multiple rings into one continuous pass with a connecting transition")
    func testPocketChainsMultipleRingsIntoOnePass() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0, stepdown: 1.0, stepoverPercentage: 0.5)
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

        let waypoints = toolpaths[0].passes[0].waypoints

        // rapid + plunge + (4 ring-0 corners + 1 transition + 4 ring-1 corners) + retract.
        #expect(waypoints.count == 12,
                "Test Failed: expected 12 waypoints for a 2-ring chained pocket, got \(waypoints.count)")

        // Only one plunge for the whole chained pass -- Z stepdown per ring is
        // explicitly out of scope until Step 2.5.
        #expect(waypoints[0].position.z == 5.0, "Test Failed: expected the initial rapid at safeZ")
        #expect(waypoints[1].position.z == -1.0, "Test Failed: expected a single plunge to targetDepth")

        // The transition waypoint (index 6) is the lateral step from ring 0's
        // closing point into ring 1's start corner -- proof the rings were
        // actually chained, not just concatenated as two separate passes.
        let transition = waypoints[6]
        #expect(abs(transition.position.x - 4.0) < 1e-5 && abs(transition.position.y - 4.0) < 1e-5,
                "Test Failed: expected the ring-0-to-ring-1 transition to land on ring 1's start corner")

        // Ring 1 traces its own four corners after the transition, closing back
        // on itself before the final retract.
        let ring1Close = waypoints[10]
        #expect(abs(ring1Close.position.x - 4.0) < 1e-5 && abs(ring1Close.position.y - 4.0) < 1e-5,
                "Test Failed: expected ring 1 to close back on its own start corner")

        #expect(waypoints[11].position.z == 5.0, "Test Failed: expected the final retract to safeZ")
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
