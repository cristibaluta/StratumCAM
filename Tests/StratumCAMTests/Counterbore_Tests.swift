//
//  Counterbore_Tests.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 15.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

struct Counterbore_Tests {

    // MARK: - Fixtures

    private func pointContour(x: Double, y: Double) -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(x, y), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
    }

    private func settings(stepdown: Double = 1.0, stepoverPercentage: Double = 0.5, safeZ: Double = 5.0) -> SC.MachineSettings {
        SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                    plungeRate: 300.0,
                                                    stepdown: stepdown,
                                                    stepoverPercentage: stepoverPercentage),
                           safeZ: safeZ,
                           targetDepth: -999.0) // deliberately unrelated -- depth should come from the operation, never this.
    }

    /// Farthest any waypoint sits from `center` in XY, ignoring Z -- the actual radius
    /// the cutter's own center travelled to, used both to confirm the wall is fully
    /// reached and that it's never exceeded (see `testNoOvercutBeyondRequestedWall`).
    private func maxRadius(_ waypoints: [SC.Waypoint], from center: CGPoint) -> Double {
        waypoints.map { hypot(Double($0.position.x) - center.x, Double($0.position.y) - center.y) }.max() ?? 0
    }

    // MARK: - Diameter

    @Test("The recess's outer wall matches the requested diameter, offset inward by the tool radius")
    func testDiameterDrivesOuterWallRadius() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0) // tool radius 2.0
        let center = CGPoint(x: 5, y: 5)

        let toolpaths = try engine.generateToolpaths(
            from: [pointContour(x: 5, y: 5)],
            tool: tool,
            settings: settings(),
            operation: .counterbore(diameter: 20.0, depth: 1.0, direction: .climb, entry: .plunge)
        )

        #expect(toolpaths.count == 1, "Test Failed: expected 1 counterbore toolpath")
        let waypoints = toolpaths[0].passes[0].waypoints

        let expectedWallRadius = 20.0 / 2.0 - 2.0 // target radius minus tool radius
        #expect(abs(maxRadius(waypoints, from: center) - expectedWallRadius) < 1e-6,
                "Test Failed: the cutter should reach exactly diameter/2 - toolRadius from center, not short of or past it")
    }

    // MARK: - Depth

    @Test("depth (not settings.targetDepth) determines how deep the recess goes")
    func testDepthDrivesZPassesIndependentlyOfSettingsTargetDepth() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0)

        let toolpaths = try engine.generateToolpaths(
            from: [pointContour(x: 0, y: 0)],
            tool: tool,
            settings: settings(stepdown: 1.0), // settings.targetDepth is -999.0, must be ignored
            operation: .counterbore(diameter: 20.0, depth: 2.0, direction: .climb, entry: .plunge)
        )

        let passes = toolpaths[0].passes
        #expect(passes.count == 2, "Test Failed: expected 2 Z passes for a -2.0 depth at 1.0 stepdown, got \(passes.count)")
        #expect(passes[0].depthZ == -1.0, "Test Failed: pass 0 depth mismatch")
        #expect(passes[1].depthZ == -2.0, "Test Failed: pass 1 should land exactly on the counterbore's own depth, not settings.targetDepth")
    }

    @Test("depth greater than one stepdown produces multiple passes reusing identical XY geometry")
    func testDepthGreaterThanOneStepdownReusesGeometryAcrossPasses() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0)

        let toolpaths = try engine.generateToolpaths(
            from: [pointContour(x: 3, y: 4)],
            tool: tool,
            settings: settings(stepdown: 1.0),
            operation: .counterbore(diameter: 16.0, depth: 3.2, direction: .climb, entry: .plunge)
        )

        let passes = toolpaths[0].passes
        // -3.2 / 1.0 -> rounds up to 4 passes: -1.0, -2.0, -3.0, -3.2 (same fencepost rule
        // `calculateZPasses` already covers elsewhere).
        #expect(passes.count == 4, "Test Failed: expected 4 Z passes, got \(passes.count)")
        #expect(passes[0].depthZ == -1.0 && passes[1].depthZ == -2.0 && passes[2].depthZ == -3.0 && passes[3].depthZ == -3.2,
                "Test Failed: unexpected depth sequence \(passes.map { $0.depthZ })")

        let firstPassXY = passes[0].waypoints.map { (Double($0.position.x), Double($0.position.y)) }
        for pass in passes.dropFirst() {
            let xy = pass.waypoints.map { (Double($0.position.x), Double($0.position.y)) }
            #expect(xy.count == firstPassXY.count, "Test Failed: every pass should trace identical ring geometry -- waypoint counts differ")
            for (a, b) in zip(firstPassXY, xy) {
                #expect(abs(a.0 - b.0) < 1e-9 && abs(a.1 - b.1) < 1e-9,
                        "Test Failed: ring geometry should be identical across passes -- only Z should change")
            }
        }
    }

    // MARK: - Helical descent

    @Test("A .helix entry spirals gradually down to depth rather than plunging straight down")
    func testHelicalDescentEntersGradually() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0)

        let toolpaths = try engine.generateToolpaths(
            from: [pointContour(x: 0, y: 0)],
            tool: tool,
            settings: settings(stepdown: 1.0),
            operation: .counterbore(diameter: 20.0, depth: 1.0, direction: .climb, entry: .helix(radius: 1.0, rampAngleDegrees: 30))
        )

        let waypoints = toolpaths[0].passes[0].waypoints

        // [0] rapid to the innermost ring's start point at safeZ.
        #expect(waypoints[0].position.z == 5.0, "Test Failed: should still rapid in at safeZ first")
        if case .rapid = waypoints[0].motion {} else {
            Issue.record("Test Failed: first waypoint motion must be .rapid")
        }

        // The helix itself: several arc moves immediately following the rapid, each
        // descending a bit further than the last, none of them landing at full depth
        // until the very last turn -- a plunge entry would instead go rapid -> one
        // .linear move straight to -1.0.
        func isArcMotion(_ motion: SC.MotionType) -> Bool {
            switch motion {
                case .arcCW, .arcCCW: return true
                default: return false
            }
        }

        #expect(isArcMotion(waypoints[1].motion), "Test Failed: expected a helical (arc) entry move right after the rapid, got \(waypoints[1].motion)")

        let helixTurns = waypoints.dropFirst().prefix { isArcMotion($0.motion) }
        #expect(helixTurns.count > 1, "Test Failed: expected multiple helical turns spiralling down, got \(helixTurns.count)")

        let helixZs = helixTurns.map { Double($0.position.z) }
        guard let firstHelixZ = helixZs.first, let lastHelixZ = helixZs.last else {
            Issue.record("Test Failed: expected at least one helical turn")
            return
        }
        #expect(firstHelixZ > -1.0 + 1e-6, "Test Failed: the helix's first turn should not already be at full depth")
        #expect(abs(lastHelixZ - (-1.0)) < 1e-6, "Test Failed: the helix should land exactly at target depth by its final turn")

        // Strictly non-increasing Z as the helix spirals down (each turn at or below
        // the previous one).
        for i in 1..<helixZs.count {
            #expect(helixZs[i] <= helixZs[i - 1] + 1e-9, "Test Failed: helix Z should never climb back up mid-descent")
        }
    }

    // MARK: - Final wall radius

    @Test("counterboreRings' outermost ring always lands exactly on diameter/2 - toolRadius")
    func testFinalWallRadiusAlwaysExact() {
        let engine = SCEngine()
        let center = CGPoint(x: 0, y: 0)

        // Deliberately uneven spacing: stepover (2.0) doesn't divide wallRadius (7.0) evenly.
        let rings = engine.counterboreRings(center: center, toolRadius: 2.0, wallRadius: 7.0, stepover: 2.0, isCCW: true)

        #expect(!rings.isEmpty, "Test Failed: expected at least one ring")
        guard case .arc(_, let lastRadius, _, _, _) = rings.last?.first else {
            Issue.record("Test Failed: expected the last ring to be arc geometry")
            return
        }
        #expect(abs(lastRadius - 7.0) < 1e-9, "Test Failed: last ring must land exactly on wallRadius even with uneven spacing, got \(lastRadius)")
    }

    @Test("A counterbore too small for even one stepover still produces a single wall-radius ring")
    func testSingleRingWhenWallRadiusSmallerThanOneStepover() {
        let engine = SCEngine()
        let center = CGPoint(x: 0, y: 0)

        // toolRadius (2.0) already exceeds wallRadius (1.5), so the first-ring cap
        // alone is enough to skip straight to the final wall-radius ring -- no
        // intermediate stepover band fits at all.
        let rings = engine.counterboreRings(center: center, toolRadius: 2.0, wallRadius: 1.5, stepover: 4.0, isCCW: true)

        #expect(rings.count == 1, "Test Failed: expected exactly one ring, got \(rings.count)")
        guard case .arc(_, let radius, _, _, _) = rings.first?.first else {
            Issue.record("Test Failed: expected arc geometry")
            return
        }
        #expect(abs(radius - 1.5) < 1e-9, "Test Failed: the single ring should sit exactly at the wall radius")
    }

    // MARK: - No overcut

    @Test("No waypoint ever travels past the requested wall radius")
    func testNoOvercutBeyondRequestedWall() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0) // tool radius 1.5
        let center = CGPoint(x: 2, y: -3)

        let toolpaths = try engine.generateToolpaths(
            from: [pointContour(x: 2, y: -3)],
            tool: tool,
            settings: settings(stepdown: 0.5, stepoverPercentage: 0.35),
            operation: .counterbore(diameter: 25.0, depth: 1.5, direction: .conventional, entry: .helix(radius: 1.0, rampAngleDegrees: 20))
        )

        let expectedWallRadius = 25.0 / 2.0 - 1.5

        for pass in toolpaths[0].passes {
            for waypoint in pass.waypoints {
                let r = hypot(Double(waypoint.position.x) - center.x, Double(waypoint.position.y) - center.y)
                #expect(r <= expectedWallRadius + 1e-6, "Test Failed: waypoint at radius \(r) overcuts the requested wall (\(expectedWallRadius))")
            }
        }
    }

    // MARK: - Different tool diameters

    @Test("Different tool diameters all reach the same requested diameter without overcutting it")
    func testDifferentToolDiametersReachSameRequestedDiameter() throws {
        let engine = SCEngine()
        let targetDiameter = 18.0
        let center = CGPoint(x: 0, y: 0)

        for toolDiameter in [2.0, 3.175, 6.0, 8.0] {
            let tool = SC.ToolParams(type: .flatEndMill, diameter: toolDiameter)

            let toolpaths = try engine.generateToolpaths(
                from: [pointContour(x: 0, y: 0)],
                tool: tool,
                settings: settings(),
                operation: .counterbore(diameter: targetDiameter, depth: 1.0, direction: .climb, entry: .plunge)
            )

            #expect(toolpaths.count == 1, "Test Failed: tool diameter \(toolDiameter) should still produce a toolpath")
            let waypoints = toolpaths[0].passes[0].waypoints

            let expectedWallRadius = targetDiameter / 2.0 - toolDiameter / 2.0
            #expect(abs(maxRadius(waypoints, from: center) - expectedWallRadius) < 1e-6,
                    "Test Failed: tool diameter \(toolDiameter) should reach exactly \(expectedWallRadius), got \(maxRadius(waypoints, from: center))")
        }
    }

    // MARK: - Tool larger than requested diameter -> reject

    // Step 6.5: this used to assert that a too-large tool silently produced an empty
    // toolpaths array. It now throws `SC.Error.toolIncompatible` instead -- same
    // "propagate rather than swallow" change 6.2-6.4 made for the other operations --
    // so the test asserts the throw rather than an empty result.
    @Test("A tool wider than the requested diameter throws toolIncompatible, not silently produces nothing")
    func testToolLargerThanDiameterThrowsToolIncompatible() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 20.0) // wider than the requested 10.0 bore

        // do/catch rather than #expect(throws:) -- matching Drilling_Tests.swift's own
        // note on why (the exact-value overload of #expect(throws:) isn't pinned across
        // Swift Testing releases in this package).
        do {
            _ = try engine.generateToolpaths(
                from: [pointContour(x: 0, y: 0)],
                tool: tool,
                settings: settings(),
                operation: .counterbore(diameter: 10.0, depth: 1.0, direction: .climb, entry: .plunge)
            )
            Issue.record("Test Failed: expected SC.Error.toolIncompatible to be thrown")
        } catch SC.Error.toolIncompatible {
            // expected
        } catch {
            Issue.record("Test Failed: expected SC.Error.toolIncompatible, got \(error)")
        }
    }

    @Test("A tool exactly matching the requested diameter also throws toolIncompatible -- it would leave no wall to actually offset")
    func testToolExactlyMatchingDiameterThrowsToolIncompatible() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 10.0)

        do {
            _ = try engine.generateToolpaths(
                from: [pointContour(x: 0, y: 0)],
                tool: tool,
                settings: settings(),
                operation: .counterbore(diameter: 10.0, depth: 1.0, direction: .climb, entry: .plunge)
            )
            Issue.record("Test Failed: expected SC.Error.toolIncompatible to be thrown")
        } catch SC.Error.toolIncompatible {
            // expected
        } catch {
            Issue.record("Test Failed: expected SC.Error.toolIncompatible, got \(error)")
        }
    }

    // MARK: - Non drill-point contour

    // Step 6.5: this used to assert that a non-drill-point contour silently produced an
    // empty toolpaths array. It now throws `SC.Error.missingDrillPoint` instead, same
    // as `.drilling`/`.boring` already do.
    @Test("A non-drill-point contour throws missingDrillPoint")
    func testNonDrillPointContourThrows() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0)

        let contour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        do {
            _ = try engine.generateToolpaths(
                from: [contour],
                tool: tool,
                settings: settings(),
                operation: .counterbore(diameter: 20.0, depth: 1.0, direction: .climb, entry: .plunge)
            )
            Issue.record("Test Failed: expected SC.Error.missingDrillPoint to be thrown")
        } catch SC.Error.missingDrillPoint {
            // expected
        } catch {
            Issue.record("Test Failed: expected SC.Error.missingDrillPoint, got \(error)")
        }
    }
}
