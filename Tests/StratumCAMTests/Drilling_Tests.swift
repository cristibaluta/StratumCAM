//
//  Drilling.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Testing
import CoreGraphics
import simd
@testable import StratumCAM

// Covers point-contour recognition and both plain and peck-cycle drill cycles for `.drilling`.

struct Drilling_Tests {

    // MARK: - Point recognition

    @Test("A single .point entity is recognized as a drill point")
    func testPointEntityIsRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(geometry: .point(at: SIMD2<Double>(5, 7)), reversed: false)
        ], isClosed: false)

        let point = contour.drillPoint

        #expect(point != nil, "Test Failed: expected a drill point")
        #expect(point!.x ~= 5.0 && point!.y ~= 7.0, "Test Failed: drill point XY mismatch")
    }

    @Test("A single closed circle is recognized as a drill point at its center")
    func testClosedCircleIsRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(geometry: .circle(center: SIMD2<Double>(3, 4), radius: 2.5), reversed: false)
        ], isClosed: true)

        let point = contour.drillPoint

        #expect(point != nil, "Test Failed: expected a drill point")
        #expect(point!.x ~= 3.0 && point!.y ~= 4.0, "Test Failed: drill point should be the circle's center")
    }

    @Test("A circle marked as not closed is not treated as a drill point")
    func testOpenCircleIsNotRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(geometry: .circle(center: SIMD2<Double>(3, 4), radius: 2.5), reversed: false)
        ], isClosed: false)

        #expect(contour.drillPoint == nil, "Test Failed: an unclosed circle should not resolve to a drill point")
    }

    @Test("A line is not recognized as a drill point")
    func testLineIsNotRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(10, 0)), reversed: false)
        ], isClosed: false)

        #expect(contour.drillPoint == nil, "Test Failed: a line should not resolve to a drill point")
    }

    @Test("A multi-entity contour is not recognized as a drill point")
    func testMultiEntityContourIsNotRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(10, 0)), reversed: false),
            .init(geometry: .point(at: SIMD2<Double>(5, 5)), reversed: false)
        ], isClosed: false)

        #expect(contour.drillPoint == nil, "Test Failed: a multi-entity contour should not resolve to a single drill point")
    }

    // MARK: - Basic drill cycle

    @Test("A plain drill cycle plunges straight down and retracts at the point location")
    func testDrillingPlungesAndRetractsAtPointLocation() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, targetDepth: -8.0)

        let contour = SC.Contour(entities: [
            .init(geometry: .point(at: SIMD2<Double>(12, 20)), reversed: false)
        ], isClosed: false)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings, operation: .drilling(peckDepth: nil))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 1, "Test Failed: a plain drill cycle should be a single pass")

        let waypoints = toolpath.passes[0].waypoints
        #expect(waypoints.count == 3, "Test Failed: expected rapid-plunge-retract, got \(waypoints.count) waypoints")

        // [0] Rapid to (12, 20) @ SafeZ
        let wp0 = waypoints[0]
        #expect(wp0.position.x ~= 12.0 && wp0.position.y ~= 20.0 && wp0.position.z == 5.0,
                "Test Failed: initial rapid move incorrect")
        if case .rapid = wp0.motion {} else {
            Issue.record("Test Failed: first waypoint motion must be .rapid")
        }

        // [1] Plunge straight to target depth
        let wp1 = waypoints[1]
        #expect(wp1.position.x ~= 12.0 && wp1.position.y ~= 20.0, "Test Failed: plunge XY mismatch")
        #expect(wp1.position.z == -8.0, "Test Failed: plunge Z mismatch")
        #expect(wp1.feedRate == 200.0, "Test Failed: plunge feed rate should match settings")
        if case .linear = wp1.motion {} else {
            Issue.record("Test Failed: plunge motion must be .linear")
        }

        // [2] Retract back to SafeZ
        let wp2 = waypoints[2]
        #expect(wp2.position.x ~= 12.0 && wp2.position.y ~= 20.0, "Test Failed: retract XY mismatch")
        #expect(wp2.position.z == 5.0, "Test Failed: retract Z mismatch")
        if case .rapid = wp2.motion {} else {
            Issue.record("Test Failed: retract motion must be .rapid")
        }
    }

    @Test("A drill cycle from a closed circle contour drills at the circle's center")
    func testDrillingUsesCircleCenterAsHoleLocation() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 250.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 6.0, targetDepth: -5.0)

        let contour = SC.Contour(entities: [
            .init(geometry: .circle(center: SIMD2<Double>(1, 2), radius: 2.0), reversed: false)
        ], isClosed: true)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings, operation: .drilling(peckDepth: nil))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let wp1 = toolpaths[0].passes[0].waypoints[1]
        #expect(wp1.position.x ~= 1.0 && wp1.position.y ~= 2.0, "Test Failed: drill should plunge at the circle's center")
        #expect(wp1.position.z == -5.0, "Test Failed: plunge Z mismatch")
    }

    // MARK: - Any closed shape drills at its bounding-box center

    // Not a point or a closed circle -- `drillPoint` returns `nil` for this shape --
    // but it's closed, so `closedShapeCenter` picks it up and `.drilling` still
    // resolves a hole location instead of throwing. This is what makes something
    // like pre-drilling a stress-relief hole in the middle of an arbitrary pocket
    // boundary possible without also having to draw a separate point/circle marker
    // at the same spot.
    @Test("closedShapeCenter is the bounding-box center of a closed contour")
    func testClosedShapeCenterIsBoundingBoxCenter() {
        let square = SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(20, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(20, 0), b: SIMD2<Double>(20, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(20, 10), b: SIMD2<Double>(0, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, 10), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true)

        let center = square.closedShapeCenter

        #expect(center != nil, "Test Failed: expected a center for a closed square")
        #expect(center!.x ~= 10.0 && center!.y ~= 5.0, "Test Failed: expected the bounding-box center of the square")
    }

    @Test("closedShapeCenter is nil for an open contour")
    func testClosedShapeCenterIsNilWhenNotClosed() {
        let openSquare = SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(20, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(20, 0), b: SIMD2<Double>(20, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(20, 10), b: SIMD2<Double>(0, 10)), reversed: false)
        ], isClosed: false)

        #expect(openSquare.closedShapeCenter == nil, "Test Failed: an open contour has no well-defined center")
    }

    @Test("A closed square with no point/circle marker still drills, at its bounding-box center")
    func testDrillingClosedSquareDrillsAtBoundingBoxCenter() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, targetDepth: -6.0)

        let square = SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(10, 10), b: SIMD2<Double>(30, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(30, 10), b: SIMD2<Double>(30, 30)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(30, 30), b: SIMD2<Double>(10, 30)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(10, 30), b: SIMD2<Double>(10, 10)), reversed: false)
        ], isClosed: true)

        let toolpaths = try engine.generateToolpaths(from: [square], tool: tool, settings: settings, operation: .drilling(peckDepth: nil))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let wp1 = toolpaths[0].passes[0].waypoints[1]
        #expect(wp1.position.x ~= 20.0 && wp1.position.y ~= 20.0, "Test Failed: drill should plunge at the square's bounding-box center")
        #expect(wp1.position.z == -6.0, "Test Failed: plunge Z mismatch")
    }

    // Same shape as the test above, minus its last side -- an open boundary has no
    // well-defined center (`closedShapeCenter` returns `nil` for it, same as
    // `drillPoint`), so this still has to throw rather than guess a location.
    @Test("An open, non-drill-point contour still throws missingDrillPoint")
    func testDrillingOpenMultiEntityContourStillThrows() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, targetDepth: -6.0)

        let openSquare = SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(10, 10), b: SIMD2<Double>(30, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(30, 10), b: SIMD2<Double>(30, 30)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(30, 30), b: SIMD2<Double>(10, 30)), reversed: false)
        ], isClosed: false)

        do {
            _ = try engine.generateToolpaths(from: [openSquare], tool: tool, settings: settings, operation: .drilling(peckDepth: nil))
            Issue.record("Test Failed: expected SC.Error.missingDrillPoint to be thrown")
        } catch SC.Error.missingDrillPoint {
            // expected
        } catch {
            Issue.record("Test Failed: expected SC.Error.missingDrillPoint, got \(error)")
        }
    }

    // Step 6.2: this used to assert that a non-drill-point contour silently produced
    // an empty toolpaths array. It now throws `SC.Error.missingDrillPoint` instead --
    // that's the whole point of Track 6, not a regression -- so the test asserts the
    // throw rather than an empty result. This particular contour (a single open line)
    // stays a throwing case even after `closedShapeCenter`'s fallback was added above,
    // since it's still open, not just an unrecognized shape.
    @Test("A non-drill-point contour throws missingDrillPoint")
    func testDrillingNonDrillPointContourThrows() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, targetDepth: -8.0)

        let contour = SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(10, 0)), reversed: false)
        ], isClosed: false)

        // do/catch + Issue.record rather than #expect(throws:) -- the exact-value
        // overload of #expect(throws:) has shifted across Swift Testing releases and
        // this package doesn't pin one (it's part of the toolchain, not Package.resolved),
        // so do/catch is the version-safe choice here, matching Issue.record's use
        // elsewhere in this file.
        do {
            _ = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings, operation: .drilling(peckDepth: nil))
            Issue.record("Test Failed: expected SC.Error.missingDrillPoint to be thrown")
        } catch SC.Error.missingDrillPoint {
            // expected
        } catch {
            Issue.record("Test Failed: expected SC.Error.missingDrillPoint, got \(error)")
        }
    }

    // MARK: - Peck drilling

    @Test("Peck drilling with an evenly divisible depth produces exactly the right number of pecks")
    func testPeckDrillingEvenDivisionProducesExactPeckCount() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, retractZ: 1.0, targetDepth: 8.0)

        let contour = SC.Contour(entities: [
            .init(geometry: .point(at: SIMD2<Double>(10, 10)), reversed: false)
        ], isClosed: false)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings, operation: .drilling(peckDepth: 4.0))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 1, "Test Failed: peck drilling should still be a single ToolpathPass")

        let waypoints = toolpath.passes[0].waypoints
        // 1 initial rapid to Safe Z, then 2 pecks x (plunge + retract) = 1 + 4 = 5 waypoints.
        #expect(waypoints.count == 5, "Test Failed: expected 5 waypoints for 2 pecks, got \(waypoints.count)")

        // [0] Initial rapid to Safe Z
        #expect(waypoints[0].position.z == 5.0, "Test Failed: initial move should be at Safe Z")
        if case .rapid = waypoints[0].motion {} else {
            Issue.record("Test Failed: initial waypoint motion must be .rapid")
        }

        // [1] First peck plunges to -4.0
        #expect(waypoints[1].position.z == -4.0, "Test Failed: first peck should stop at -4.0")
        #expect(waypoints[1].feedRate == 200.0, "Test Failed: peck plunge should use plunge feed rate")
        if case .linear = waypoints[1].motion {} else {
            Issue.record("Test Failed: peck plunge motion must be .linear")
        }

        // [2] Retract between pecks goes only to retractZ, not Safe Z
        #expect(waypoints[2].position.z == 1.0, "Test Failed: between-peck retract should go to retractZ")
        if case .rapid = waypoints[2].motion {} else {
            Issue.record("Test Failed: between-peck retract motion must be .rapid")
        }

        // [3] Second (final) peck plunges to full target depth
        #expect(waypoints[3].position.z == -8.0, "Test Failed: final peck should land exactly on target depth")
        if case .linear = waypoints[3].motion {} else {
            Issue.record("Test Failed: final peck plunge motion must be .linear")
        }

        // [4] Final retract goes all the way to Safe Z
        #expect(waypoints[4].position.z == 5.0, "Test Failed: final retract after last peck should go to Safe Z")
        if case .rapid = waypoints[4].motion {} else {
            Issue.record("Test Failed: final retract motion must be .rapid")
        }

        // XY stays fixed at the hole location throughout the cycle.
        for wp in waypoints {
            #expect(wp.position.x ~= 10.0 && wp.position.y ~= 10.0,
                    "Test Failed: peck cycle should stay at the hole's XY throughout")
        }
    }

    @Test("Peck drilling with an unevenly divisible depth ends exactly on target depth")
    func testPeckDrillingUnevenDivisionEndsAtTargetDepth() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, retractZ: 1.0, targetDepth: 10.0)

        let contour = SC.Contour(entities: [
            .init(geometry: .point(at: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: false)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings, operation: .drilling(peckDepth: 4.0))

        let waypoints = toolpaths[0].passes[0].waypoints
        // 10.0 / 4.0 -> 2.5 -> rounds up to 3 pecks (4, 8, 10).
        // 1 initial rapid + 3 pecks x (plunge + retract) = 7 waypoints.
        #expect(waypoints.count == 7, "Test Failed: expected 7 waypoints for 3 pecks, got \(waypoints.count)")

        let plungeDepths = [waypoints[1].position.z, waypoints[3].position.z, waypoints[5].position.z]
        #expect(plungeDepths == [-4.0, -8.0, -10.0], "Test Failed: peck depths should be -4.0, -8.0, -10.0, got \(plungeDepths)")

        // Only the very last retract should reach Safe Z; the rest stop at retractZ.
        #expect(waypoints[2].position.z == 1.0 && waypoints[4].position.z == 1.0,
                "Test Failed: intermediate retracts should stop at retractZ")
        #expect(waypoints[6].position.z == 5.0, "Test Failed: final retract should reach Safe Z")
    }

    @Test("Peck drilling from a closed circle contour pecks at the circle's center")
    func testPeckDrillingUsesCircleCenterAsHoleLocation() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 250.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 6.0, retractZ: 1.5, targetDepth: 6.0)

        let contour = SC.Contour(entities: [
            .init(geometry: .circle(center: SIMD2<Double>(1, 2), radius: 2.0), reversed: false)
        ], isClosed: true)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings, operation: .drilling(peckDepth: 3.0))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let waypoints = toolpaths[0].passes[0].waypoints
        for wp in waypoints {
            #expect(wp.position.x ~= 1.0 && wp.position.y ~= 2.0,
                    "Test Failed: peck cycle should stay at the circle's center")
        }
        #expect(waypoints.last?.position.z == 6.0, "Test Failed: final retract should reach Safe Z")
    }

    @Test("A zero or negative peck depth falls back to a plain drill cycle")
    func testNonPositivePeckDepthFallsBackToPlainDrillCycle() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, targetDepth: 8.0)

        let contour = SC.Contour(entities: [
            .init(geometry: .point(at: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: false)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings, operation: .drilling(peckDepth: 0.0))

        let waypoints = toolpaths[0].passes[0].waypoints
        #expect(waypoints.count == 3, "Test Failed: a non-positive peck depth should behave like a plain drill cycle")
        #expect(waypoints[1].position.z == -8.0, "Test Failed: plunge should still reach full target depth")
    }

    // MARK: - Multiple drill points / mixed operations (Step 1.4)

    @Test("Multiple drill point contours produce one toolpath per hole")
    func testMultipleDrillPointsProduceOneToolpathPerContour() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .drill, diameter: 3.0)
        let settings = SC.MachineSettings(
            cutting: SC.CuttingData(
                feedRate: 1000.0,
                plungeRate: 200.0,
                stepdown: 1.0, stepoverPercentage: 0.4
            ),
            safeZ: 5.0,
            targetDepth: 8.0
        )

        let points = [
            (10.0, 20.0),
            (30.0, 20.0),
            (30.0, 40.0),
            (10.0, 40.0)
        ]

        let contours = points.map { x, y in
            SC.Contour(
                entities: [
                    .init(
                        geometry: .point(
                            at: SIMD2<Double>(x, y)
                        ),
                        reversed: false
                    )
                ],
                isClosed: false
            )
        }

        let toolpaths = try engine.generateToolpaths(
            from: contours,
            tool: tool,
            settings: settings,
            operation: .drilling(peckDepth: nil)
        )

        #expect(
            toolpaths.count == 4,
            "Test Failed: expected one drilling toolpath per point contour"
        )

        for (toolpath, expected) in zip(toolpaths, points) {
            #expect(
                toolpath.operation == .drilling(peckDepth: nil),
                "Test Failed: operation should remain drilling without pecking"
            )

            let waypoints = toolpath.passes[0].waypoints

            #expect(
                waypoints.count == 3,
                "Test Failed: each plain hole should contain rapid-plunge-retract"
            )

            #expect(
                waypoints[1].position.x ~= expected.0 &&
                waypoints[1].position.y ~= expected.1,
                "Test Failed: toolpath was assigned to the wrong hole"
            )

            #expect(
                waypoints[1].position.z == -8.0,
                "Test Failed: every hole should reach target depth"
            )
        }
    }

    @Test("A mixed batch supports peck and non-peck drilling with different tools")
    func testMixedPeckAndNonPeckDrillingInOneCall() throws {
        let engine = SCEngine()

        let plainTool = SC.ToolParams(
            type: .drill,
            diameter: 3.0
        )

        let peckTool = SC.ToolParams(
            type: .drill,
            diameter: 6.0
        )

        let plainSettings = SC.MachineSettings(
            cutting: SC.CuttingData(
                feedRate: 1000.0,
                plungeRate: 200.0,
                stepdown: 1.0, stepoverPercentage: 0.4
            ),
            safeZ: 5.0,
            retractZ: 1.0,
            targetDepth: 6.0
        )

        let peckSettings = SC.MachineSettings(
            cutting: SC.CuttingData(
                feedRate: 800.0,
                plungeRate: 150.0,
                stepdown: 1.0, stepoverPercentage: 0.4
            ),
            safeZ: 7.0,
            retractZ: 1.5,
            targetDepth: 10.0
        )

        func pointContour(_ x: Double, _ y: Double) -> SC.Contour {
            SC.Contour(
                entities: [
                    .init(
                        geometry: .point(
                            at: SIMD2<Double>(x, y)
                        ),
                        reversed: false
                    )
                ],
                isClosed: false
            )
        }

        // Each hole is just a (contour, tool, settings, peckDepth) combination --
        // no dedicated wrapper type needed, even though tools/settings/peck depth
        // differ hole to hole. A mixed batch is just repeated calls to the same
        // per-contour `generateToolpaths` call every other strategy already uses.
        let holes: [(contour: SC.Contour, tool: SC.ToolParams, settings: SC.MachineSettings, peckDepth: Double?)] = [
            (pointContour(10, 10), plainTool, plainSettings, nil),
            (pointContour(20, 10), peckTool, peckSettings, 4.0),
            (pointContour(20, 20), plainTool, plainSettings, nil),
            (pointContour(10, 20), peckTool, peckSettings, 4.0)
        ]

        let toolpaths = try holes.flatMap { hole in
            try engine.generateToolpaths(
                from: [hole.contour],
                tool: hole.tool,
                settings: hole.settings,
                operation: .drilling(peckDepth: hole.peckDepth)
            )
        }

        #expect(
            toolpaths.count == 4,
            "Test Failed: expected one output toolpath per drilling operation"
        )

        // First operation: plain drill = rapid + plunge + retract.
        #expect(
            toolpaths[0].tool == plainTool,
            "Test Failed: first operation should use the plain-drill tool"
        )

        #expect(
            toolpaths[0].passes[0].waypoints.count == 3,
            "Test Failed: non-peck hole should have 3 waypoints"
        )

        #expect(
            toolpaths[0].passes[0].waypoints[1].position.z == -6.0,
            "Test Failed: plain hole depth mismatch"
        )

        // Second operation: peck 4 -> 8 -> 10,
        // with retractZ between pecks.
        #expect(
            toolpaths[1].tool == peckTool,
            "Test Failed: second operation should use the peck-drill tool"
        )

        let second = toolpaths[1].passes[0].waypoints

        #expect(
            second.count == 7,
            "Test Failed: 10 mm depth at 4 mm peck should produce 3 pecks"
        )

        #expect(
            second[1].position.z == -4.0 &&
            second[3].position.z == -8.0 &&
            second[5].position.z == -10.0,
            "Test Failed: second hole peck depths are incorrect"
        )

        #expect(
            second[2].position.z == 1.5 &&
            second[4].position.z == 1.5,
            "Test Failed: intermediate pecks should retract to retractZ"
        )

        #expect(
            second[6].position.z == 7.0,
            "Test Failed: final peck should retract to Safe Z"
        )

        for waypoint in second {
            #expect(
                waypoint.position.x ~= 20.0 &&
                waypoint.position.y ~= 10.0,
                "Test Failed: second hole peck cycle moved away from its hole center"
            )
        }

        // Third and fourth operations repeat the modes to ensure no state
        // leaks between holes.
        #expect(
            toolpaths[2].tool == plainTool &&
            toolpaths[2].passes[0].waypoints.count == 3,
            "Test Failed: third operation should be an independent plain drill"
        )

        #expect(
            toolpaths[3].tool == peckTool &&
            toolpaths[3].passes[0].waypoints.count == 7,
            "Test Failed: fourth operation should be an independent peck drill"
        )

        #expect(
            toolpaths[3].passes[0].waypoints[1].position.x ~= 10.0 &&
            toolpaths[3].passes[0].waypoints[1].position.y ~= 20.0,
            "Test Failed: fourth hole location mismatch"
        )
    }
}
