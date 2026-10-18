//
//  Pocket.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Testing
import CoreGraphics
import simd
@testable import StratumCAM

struct Pocket_Tests {

    // MARK: - Fixtures

    /// A 20x10 CCW rectangle.
    private func ccwRectangleContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(20, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(20, 0), b: SIMD2<Double>(20, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(20, 10), b: SIMD2<Double>(0, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, 10), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true)
    }

    /// A 20x10 CCW rounded rectangle with 2mm corner radii.
    ///
    /// Start at (2,0), travel along the bottom edge, then use quarter-circle arcs
    /// at each corner. The resulting path is CCW.
    private func roundedRectangleContour() -> SC.Contour {
        let r = 2.0

        return SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(2, 0), b: SIMD2<Double>(18, 0)), reversed: false),
            .init(geometry: .arc(center: SIMD2<Double>(18, 2), radius: r, startDeg: -90, endDeg: 0), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(20, 2), b: SIMD2<Double>(20, 8)), reversed: false),
            .init(geometry: .arc(center: SIMD2<Double>(18, 8), radius: r, startDeg: 0, endDeg: 90), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(18, 10), b: SIMD2<Double>(2, 10)), reversed: false),
            .init(geometry: .arc(center: SIMD2<Double>(2, 8), radius: r, startDeg: 90, endDeg: 180), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, 8), b: SIMD2<Double>(0, 2)), reversed: false),
            .init(geometry: .arc(center: SIMD2<Double>(2, 2), radius: r, startDeg: 180, endDeg: 270), reversed: false)
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
        .pocket(direction: direction, pattern: .offset, entry: .plunge)
    }

    // MARK: - Concentric ring stepping (Step 2.2)

    @Test("Pocket rings step inward by stepover and stop before the ring would invert")
    func testPocketRingsStepInwardAndStopAtCollapse() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0)

        let baseSegments = ccwRectangleContour().linearizedSegments
        let oriented = engine.orientedForDirection(baseSegments, side: .inside, direction: .conventional)

        let rings = engine.pocketRings(from: oriented, tool: tool, stepoverPercentage: 0.5)

        // 20x10 rectangle, 2mm tool radius, 2mm stepover: ring 0 is [2,18]x[2,8].
        // A third-ring attempt would offset the already-6mm-tall ring 1 down to a
        // height of -2 -- it must stop there rather than emit an inverted ring.
        #expect(rings.count == 2,
                "Test Failed: expected exactly 2 rings before the next stepover would invert the ring")

        let ring0Box = segmentsBBox(rings[0])
        #expect(ring0Box.minX ~= 2.0 && ring0Box.maxX ~= 18.0,
                "Test Failed: ring 0 X bounds mismatch")
        #expect(ring0Box.minY ~= 2.0 && ring0Box.maxY ~= 8.0,
                "Test Failed: ring 0 Y bounds mismatch")

        let ring1Box = segmentsBBox(rings[1])
        #expect(ring1Box.minX ~= 4.0 && ring1Box.maxX ~= 16.0,
                "Test Failed: ring 1 X bounds mismatch -- stepover not honored")
        #expect(ring1Box.minY ~= 4.0 && ring1Box.maxY ~= 6.0,
                "Test Failed: ring 1 Y bounds mismatch -- stepover not honored")
    }

    @Test("Pocket chains multiple rings into one continuous pass with a connecting transition")
    func testPocketChainsMultipleRingsIntoOnePass() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                    plungeRate: 300.0,
                                                                    stepdown: 1.0,
                                                                    stepoverPercentage: 0.5),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = try engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(direction: .conventional)
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
        #expect(transition.position.x ~= 4.0 && transition.position.y ~= 4.0,
                "Test Failed: expected the ring-0-to-ring-1 transition to land on ring 1's start corner")

        // Ring 1 traces its own four corners after the transition, closing back
        // on itself before the final retract.
        let ring1Close = waypoints[10]
        #expect(ring1Close.position.x ~= 4.0 && ring1Close.position.y ~= 4.0,
                "Test Failed: expected ring 1 to close back on its own start corner")

        #expect(waypoints[11].position.z == 5.0, "Test Failed: expected the final retract to safeZ")
    }

    // MARK: - Basic offset ring

    @Test("Pocket offsetPattern generates one inward ring for a rectangle")
    func testPocketRectangleGeneratesSingleInwardRing() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                  plungeRate: 300.0,
                                                                  stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = try engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(direction: .conventional)
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
        #expect(box.minX ~= 3.0,
                "Test Failed: inward offset minX mismatch")

        #expect(box.maxX ~= 17.0,
                "Test Failed: inward offset maxX mismatch")

        #expect(box.minY ~= 3.0,
                "Test Failed: inward offset minY mismatch")

        #expect(box.maxY ~= 7.0,
                "Test Failed: inward offset maxY mismatch")
    }

    @Test("Pocket offsetPattern preserves rounded corners while offsetting inward")
    func testPocketRoundedRectangleGeneratesSingleInwardRing() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                  plungeRate: 300.0,
                                                                  stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = try engine.generateToolpaths(
            from: [roundedRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(direction: .conventional)
        )

        #expect(toolpaths.count == 1,
                "Test Failed: expected 1 pocket toolpath")

        let waypoints = toolpaths[0].passes[0].waypoints
        let box = bbox(waypoints)

        // Original rounded rectangle is 20x10. A 1.5mm cutter radius moves the
        // boundary inward to [1.5, 18.5] x [1.5, 8.5]. Corner radius becomes 0.5mm.
        #expect(box.minX ~= 1.5,
                "Test Failed: rounded pocket minX mismatch")

        #expect(box.maxX ~= 18.5,
                "Test Failed: rounded pocket maxX mismatch")

        #expect(box.minY ~= 1.5,
                "Test Failed: rounded pocket minY mismatch")

        #expect(box.maxY ~= 8.5,
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
    func testPocketHonorsDirection() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                  plungeRate: 300.0,
                                                                  stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let climb = try engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(direction: .conventional)
        )[0].passes[0].waypoints

        let conventional = try engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(direction: .climb)
        )[0].passes[0].waypoints

        // Both paths start at the same inward corner, but their traversal direction
        // is reversed because profile's direction helper is reused.
        let climbPlunge = climb[1]

        #expect(climbPlunge.position.x ~= 3.0 &&
                climbPlunge.position.y ~= 3.0,
                "Test Failed: climb pocket should start at the inward bottom-left corner")

        let conventionalPlunge = conventional[1]

        #expect(conventionalPlunge.position.x ~= 3.0 &&
                conventionalPlunge.position.y ~= 3.0,
                "Test Failed: conventional pocket should start at the inward bottom-left corner")

        let climbFirstCut = climb[2]

        #expect(climbFirstCut.position.x ~= 3.0 &&
                climbFirstCut.position.y ~= 7.0,
                "Test Failed: climb pocket should travel upward from the start corner")

        let conventionalFirstCut = conventional[2]

        #expect(conventionalFirstCut.position.x ~= 17.0 &&
                conventionalFirstCut.position.y ~= 3.0,
                "Test Failed: conventional pocket should travel rightward from the start corner")

        let climbBox = bbox(climb)
        let conventionalBox = bbox(conventional)

        #expect(climbBox.minX ~= conventionalBox.minX)
        #expect(climbBox.maxX ~= conventionalBox.maxX)
        #expect(climbBox.minY ~= conventionalBox.minY)
        #expect(climbBox.maxY ~= conventionalBox.maxY)
    }

    // MARK: - Validation

    // Step 6.7a: this used to assert that an open contour silently produced an empty
    // toolpaths array. It now throws `SC.Error.contourNotClosed` instead.
    @Test("An open contour throws contourNotClosed")
    func testPocketRequiresClosedContour() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                  plungeRate: 300.0,
                                                                  stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let openContour = SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0),
                                b: SIMD2<Double>(10, 0)),
                  reversed: false),

            .init(geometry: .line(a: SIMD2<Double>(10, 0),
                                b: SIMD2<Double>(10, 10)),
                  reversed: false)
        ], isClosed: false)

        // do/catch rather than #expect(throws:) -- matching Drilling_Tests.swift's own
        // note on why (the exact-value overload of #expect(throws:) isn't pinned across
        // Swift Testing releases in this package).
        do {
            _ = try engine.generateToolpaths(
                from: [openContour],
                tool: tool,
                settings: settings,
                operation: pocketStrategy(direction: .conventional)
            )
            Issue.record("Test Failed: expected SC.Error.contourNotClosed to be thrown")
        } catch SC.Error.contourNotClosed {
            // expected
        } catch {
            Issue.record("Test Failed: expected SC.Error.contourNotClosed, got \(error)")
        }
    }
}
