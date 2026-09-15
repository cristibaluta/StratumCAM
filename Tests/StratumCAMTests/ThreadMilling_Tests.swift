//
//  threadMilling_Tests.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

// Covers Step 2D.1 (the helical thread-milling core -- a continuous helix stepping,
// one revolution per `pitch`, around a hole/boss's nominal diameter, radius-compensated
// for `isInternal`, finishing with a flat closing lap) and Step 2D.2 (wiring `direction`
// -- the thread's own handedness, right-hand or left-hand -- into the helix's own
// winding sense: since the cut always runs bottom-to-top, a right-hand thread sweeps
// counterclockwise as it climbs and a left-hand thread sweeps clockwise, independent
// of `isInternal` -- see `buildThreadMillingToolpath`'s own doc comment on the exact
// mapping).
//
// The cut runs bottom-to-top and enters/exits through the hole's/boss's own center --
// see `buildthreadMillingToolpath`'s doc comment for why -- so every waypoint-layout test
// below follows this fixed shape:
//   [0] Rapid to center @ SafeZ
//   [1] Rapid down center to the bottom of the thread
//   [2] Linear feed sideways to engage the wall at the mill radius, at the bottom
//   [3...]  n helical turns (ascending) + 1 flat closing lap at the top, 8 waypoints each
//   [count-2] Linear feed back to center, at the top, to disengage
//   [count-1] Rapid retract to SafeZ
// i.e. total waypoint count == 5 + (turnCount + 1) * 8, where turnCount is however many
// full-pitch (or one shortened, fencepost) revolutions `calculateZPasses` produces.

struct ThreadMilling_Tests {

    /// Handy small helper: a closed circle contour marking a hole/boss of `diameter`,
    /// centered at `center` -- the same "closed circle marks the feature" shape
    /// `tapCircle(for:)` recognizes.
    private func circleContour(center: (Double, Double), diameter: Double) -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .circle(center: DXF.Point(center.0, center.1), radius: diameter / 2.0, layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    @Test("Thread milling enters/exits through center, cuts bottom-to-top, and finishes with a flat closing lap")
    func testThreadMillingEntersAndExitsThroughCenterCuttingBottomToTop() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0) // tool radius 1.5
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -3.0)

        let contour = circleContour(center: (0, 0), diameter: 10.0) // hole radius 5.0

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 10.0))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 1, "Test Failed: thread milling should be a single pass")

        let waypoints = toolpath.passes[0].waypoints
        // [0] Rapid to center @ SafeZ
        // [1] Rapid down center to the bottom (Z=-3.0)
        // [2] Linear feed to the 3 o'clock engage point @ mill radius, still at the bottom
        // [3...10]  Turn 1: 8 arc waypoints, -3.0 -> -2.0
        // [11...18] Turn 2: 8 arc waypoints, -2.0 -> -1.0
        // [19...26] Turn 3: 8 arc waypoints, -1.0 -> 0.0
        // [27...34] Closing lap: 8 arc waypoints, flat at 0.0
        // [35] Linear feed back to center, at the top, to disengage
        // [36] Retract to SafeZ
        #expect(waypoints.count == 37, "Test Failed: expected 5 + 4*8 waypoints, got \(waypoints.count)")

        let millRadius = 5.0 - 1.5 // hole radius - tool radius

        let wp0 = waypoints[0]
        #expect(wp0.position.x == 0.0 && wp0.position.y == 0.0 && wp0.position.z == 5.0,
                "Test Failed: initial rapid should go straight to the hole's own center at Safe Z")
        if case .rapid = wp0.motion {} else {
            Issue.record("Test Failed: first waypoint motion must be .rapid")
        }

        let wp1 = waypoints[1]
        #expect(wp1.position.x == 0.0 && wp1.position.y == 0.0 && wp1.position.z == -3.0,
                "Test Failed: second waypoint should rapid straight down the center to the bottom of the thread")
        if case .rapid = wp1.motion {} else {
            Issue.record("Test Failed: second waypoint motion must be .rapid")
        }

        let wp2 = waypoints[2]
        #expect(abs(wp2.position.x - millRadius) < 1e-9 && abs(wp2.position.y) < 1e-9 && wp2.position.z == -3.0,
                "Test Failed: third waypoint should feed sideways to the mill radius, still at the bottom")
        if case .linear = wp2.motion {} else {
            Issue.record("Test Failed: engage waypoint motion must be .linear")
        }

        // End of turn 1: back at the engage XY, one pitch higher.
        let endOfTurn1 = waypoints[10]
        #expect(endOfTurn1.position.z == -2.0, "Test Failed: turn 1 should end exactly one pitch above the bottom")
        #expect(abs(endOfTurn1.position.x - millRadius) < 1e-9 && abs(endOfTurn1.position.y) < 1e-9,
                "Test Failed: a full revolution should return to the engage XY")
        // Right-hand thread sweeps CCW as it climbs bottom-to-top (see Step 2D.2's
        // coverage below for left-hand, and for handedness being independent of
        // isInternal).
        if case .arcCCW = endOfTurn1.motion {} else {
            Issue.record("Test Failed: a right-hand thread should wind .arcCCW")
        }

        // End of turn 2 and turn 3.
        #expect(waypoints[18].position.z == -1.0, "Test Failed: turn 2 should end two pitches above the bottom")
        #expect(waypoints[26].position.z == 0.0, "Test Failed: turn 3 should end at the top, Z=0")

        // Closing lap: every waypoint stays flat at the top.
        for i in 27...34 {
            #expect(waypoints[i].position.z == 0.0, "Test Failed: closing lap waypoint \(i) should stay flat at the top")
        }
        #expect(abs(waypoints[34].position.x - millRadius) < 1e-9 && abs(waypoints[34].position.y) < 1e-9,
                "Test Failed: closing lap should also return to the engage XY")

        // Disengage back to center, still at the top, before retracting -- this is the
        // move that keeps the retract from dragging back across the freshly cut thread.
        let disengage = waypoints[35]
        #expect(disengage.position.x == 0.0 && disengage.position.y == 0.0 && disengage.position.z == 0.0,
                "Test Failed: disengage move should return to center, at the top")
        if case .linear = disengage.motion {} else {
            Issue.record("Test Failed: disengage waypoint motion must be .linear")
        }

        // Final retract, straight up from center.
        let retract = waypoints[36]
        #expect(retract.position.x == 0.0 && retract.position.y == 0.0 && retract.position.z == 5.0,
                "Test Failed: final retract should reach Safe Z, straight up from center")
        if case .rapid = retract.motion {} else {
            Issue.record("Test Failed: final retract motion must be .rapid")
        }
    }

    @Test("Internal threading compensates the mill radius inward from the hole's diameter")
    func testInternalThreadingOffsetsInward() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0) // tool radius 2.0
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = circleContour(center: (10, 20), diameter: 12.0) // hole radius 6.0

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 2.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 12.0))

        // waypoints[2] is the wall-engage move -- the first waypoint actually offset to
        // the compensated mill radius (waypoints 0-1 are the center entry).
        let engage = toolpaths[0].passes[0].waypoints[2]
        // Expected mill radius: 6.0 - 2.0 = 4.0, offset from the hole's own center.
        #expect(abs(engage.position.x - (10.0 + 4.0)) < 1e-9 && abs(engage.position.y - 20.0) < 1e-9,
                "Test Failed: internal threading should orbit inside the drawn diameter by the tool's radius")
    }

    @Test("External threading compensates the mill radius outward from the boss's diameter")
    func testExternalThreadingOffsetsOutward() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0) // tool radius 2.0
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = circleContour(center: (10, 20), diameter: 12.0) // boss radius 6.0

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 2.0, isInternal: false, direction: .rightHand, radialPasses: 1, targetDiameter: 12.0))

        let engage = toolpaths[0].passes[0].waypoints[2]
        // Expected mill radius: 6.0 + 2.0 = 8.0, offset from the boss's own center.
        #expect(abs(engage.position.x - (10.0 + 8.0)) < 1e-9 && abs(engage.position.y - 20.0) < 1e-9,
                "Test Failed: external threading should orbit outside the drawn diameter by the tool's radius")
    }

    // Step 6.6: this used to assert that a too-large tool silently produced an empty
    // toolpaths array. It now throws `SC.Error.toolIncompatible` instead -- same
    // "propagate rather than swallow" change 6.2-6.5 made for the other operations --
    // so the test asserts the throw rather than an empty result.
    @Test("Thread milling a hole not much bigger than the tool itself throws toolIncompatible")
    func testToolTooLargeForInternalHoleThrowsToolIncompatible() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 10.0) // tool radius 5.0
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = circleContour(center: (0, 0), diameter: 8.0) // hole radius 4.0, smaller than the tool radius

        // do/catch rather than #expect(throws:) -- matching Drilling_Tests.swift's own
        // note on why (the exact-value overload of #expect(throws:) isn't pinned across
        // Swift Testing releases in this package).
        do {
            _ = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                              operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 8.0))
            Issue.record("Test Failed: expected SC.Error.toolIncompatible to be thrown")
        } catch SC.Error.toolIncompatible {
            // expected
        } catch {
            Issue.record("Test Failed: expected SC.Error.toolIncompatible, got \(error)")
        }
    }

    // Step 6.6: this used to assert that a non-circle contour silently produced an
    // empty toolpaths array. It now throws `SC.Error.invalidContour` instead.
    @Test("A non-circle contour throws invalidContour")
    func testNonCircleContourThrowsInvalidContour() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        do {
            _ = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                              operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 10.0))
            Issue.record("Test Failed: expected SC.Error.invalidContour to be thrown")
        } catch SC.Error.invalidContour {
            // expected
        } catch {
            Issue.record("Test Failed: expected SC.Error.invalidContour, got \(error)")
        }
    }

    // Step 6.6: this used to assert that a zero pitch silently produced an empty
    // toolpaths array. It now throws `SC.Error.invalidParameter("pitch")` instead.
    @Test("A zero pitch throws invalidParameter")
    func testZeroPitchThrowsInvalidParameter() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = circleContour(center: (0, 0), diameter: 10.0)

        do {
            _ = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                              operation: .threadMilling(pitch: 0.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 10.0))
            Issue.record("Test Failed: expected SC.Error.invalidParameter to be thrown")
        } catch SC.Error.invalidParameter("pitch") {
            // expected
        } catch {
            Issue.record("Test Failed: expected SC.Error.invalidParameter(\"pitch\"), got \(error)")
        }
    }

    // New in Step 6.6, no prior nil-returning equivalent existed for this guard: a
    // `radialPasses` count that can't produce even one pass now throws
    // `SC.Error.invalidParameter("radialPasses")` rather than silently producing
    // nothing (the guard existed before this step, but nothing exercised it).
    @Test("A radialPasses count below 1 throws invalidParameter")
    func testRadialPassesBelowOneThrowsInvalidParameter() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = circleContour(center: (0, 0), diameter: 10.0)

        do {
            _ = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                              operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 0, targetDiameter: 10.0))
            Issue.record("Test Failed: expected SC.Error.invalidParameter to be thrown")
        } catch SC.Error.invalidParameter("radialPasses") {
            // expected
        } catch {
            Issue.record("Test Failed: expected SC.Error.invalidParameter(\"radialPasses\"), got \(error)")
        }
    }

    // MARK: - Winding direction (Step 2D.2)

    /// Reads the winding sense off the first arc waypoint (index 3 -- right after the
    /// two setup rapids to center and the linear wall-engage move) for a single-turn
    /// thread mill, so each case below only needs to check one waypoint rather than
    /// re-deriving the full waypoint layout.
    private func firstArcIsCCW(isInternal: Bool, direction: SC.ThreadDirection) -> Bool {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -1.0)
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 1.0, isInternal: isInternal, direction: direction, radialPasses: 1, targetDiameter: 10.0))

        guard case .arcCCW = toolpaths[0].passes[0].waypoints[3].motion else {
            return false
        }
        return true
    }

    @Test("A right-hand thread on an internal hole winds CCW as it climbs")
    func testInternalRightHandWindsCCW() {
        #expect(firstArcIsCCW(isInternal: true, direction: .rightHand) == true,
                "Test Failed: right-hand should wind CCW")
    }

    @Test("A left-hand thread on an internal hole winds CW as it climbs")
    func testInternalLeftHandWindsCW() {
        #expect(firstArcIsCCW(isInternal: true, direction: .leftHand) == false,
                "Test Failed: left-hand should wind CW")
    }

    @Test("A right-hand thread on an external boss also winds CCW -- handedness doesn't flip with isInternal")
    func testExternalRightHandWindsCCW() {
        #expect(firstArcIsCCW(isInternal: false, direction: .rightHand) == true,
                "Test Failed: right-hand should wind CCW regardless of isInternal -- a right-hand nut only mates with a right-hand bolt")
    }

    @Test("A left-hand thread on an external boss also winds CW -- handedness doesn't flip with isInternal")
    func testExternalLeftHandWindsCW() {
        #expect(firstArcIsCCW(isInternal: false, direction: .leftHand) == false,
                "Test Failed: left-hand should wind CW regardless of isInternal")
    }

    @Test("threadMilling a batch of holes assigns each toolpath to its own hole location")
    func testthreadMillingBatchOfHolesEachGetsOwnToolpath() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0) // tool radius 1.5
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let centers: [(Double, Double)] = [(0, 0), (20, 0), (20, 20), (0, 20)]
        let contours = centers.map { circleContour(center: $0, diameter: 10.0) } // hole radius 5.0

        let toolpaths = try engine.generateToolpaths(from: contours, tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 10.0))

        #expect(toolpaths.count == 4, "Test Failed: expected one thread-milling toolpath per hole contour")

        let millRadius = 5.0 - 1.5
        for (toolpath, center) in zip(toolpaths, centers) {
            let entry = toolpath.passes[0].waypoints[0]
            #expect(abs(entry.position.x - center.0) < 1e-9 && abs(entry.position.y - center.1) < 1e-9,
                    "Test Failed: the initial center entry was assigned to the wrong hole")

            let engage = toolpath.passes[0].waypoints[2]
            #expect(abs(engage.position.x - (center.0 + millRadius)) < 1e-9 && abs(engage.position.y - center.1) < 1e-9,
                    "Test Failed: the wall-engage move was assigned to the wrong hole")
        }
    }

    // MARK: - Additional coverage (Step 2D.3)

    @Test("A negative pitch is treated as its magnitude, same helix as the positive value")
    func testNegativePitchTreatedAsMagnitude() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -3.0)
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let positive = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 10.0))
        let negative = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                operation: .threadMilling(pitch: -1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 10.0))

        #expect(negative.count == 1, "Test Failed: a negative pitch should still produce a toolpath")
        #expect(positive[0].passes[0].waypoints.count == negative[0].passes[0].waypoints.count,
                "Test Failed: negative pitch should produce the same waypoint layout as its positive magnitude")
        for (pw, nw) in zip(positive[0].passes[0].waypoints, negative[0].passes[0].waypoints) {
            #expect(abs(pw.position.z - nw.position.z) < 1e-9, "Test Failed: negative pitch should step identically to its magnitude")
        }
    }

    @Test("A target depth that isn't an exact multiple of pitch places its shortened turn at the bottom instead of overshooting")
    func testPartialFinalTurnDepthDoesNotOvershoot() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -3.5)
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 10.0))

        let waypoints = toolpaths[0].passes[0].waypoints
        // Bottom-to-top boundaries: -3.5 -> -3 (shortened, 0.5 pitch) -> -2 -> -1 -> 0,
        // i.e. 4 helical turns + 1 closing lap, 8 waypoints each, plus the 3 setup and 2 exit moves.
        #expect(waypoints.count == 5 + 5 * 8, "Test Failed: expected a shortened 1st (bottommost) turn instead of an extra full-pitch turn")

        // wp[1] is the initial rapid straight down center -- should land exactly on the
        // true target depth, not one pitch past it.
        #expect(abs(waypoints[1].position.z - (-3.5)) < 1e-9, "Test Failed: the center entry should rapid straight to the true target depth")

        // End of turn 1 (index 3 + 8 - 1 = 10): the shortened, 0.5-pitch turn off the bottom.
        #expect(abs(waypoints[10].position.z - (-3.0)) < 1e-9, "Test Failed: the shortened first turn should land exactly half a pitch above the bottom")

        // End of turn 4 (index 3 + 4*8 - 1 = 34): the last helical turn, landing exactly at the top.
        #expect(abs(waypoints[34].position.z - 0.0) < 1e-9, "Test Failed: the final helical turn should land exactly at the top")
    }

    @Test("A target depth shallower than one full pitch still produces a single shortened turn plus closing lap")
    func testSingleShortTurnWhenDepthLessThanPitch() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -0.5)
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 10.0))

        let waypoints = toolpaths[0].passes[0].waypoints
        // 1 shortened helical turn (bottom -0.5 straight up to the top, 0.0) + 1 closing lap.
        #expect(waypoints.count == 5 + 2 * 8, "Test Failed: expected 1 shortened turn + 1 closing lap when depth < pitch")

        let endOfOnlyTurn = waypoints[10]
        #expect(abs(endOfOnlyTurn.position.z - 0.0) < 1e-9, "Test Failed: the single shortened turn should climb straight from the shallow bottom to the top")

        for i in 11...18 {
            #expect(abs(waypoints[i].position.z - 0.0) < 1e-9, "Test Failed: closing lap waypoint \(i) should stay flat at the top")
        }
    }

    @Test("Every cutting waypoint carries the machine settings' own feed rate")
    func testAllWaypointsUseCuttingFeedRate() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 733.0, plungeRate: 150.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -3.0)
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 10.0))

        for waypoint in toolpaths[0].passes[0].waypoints {
            #expect(waypoint.feedRate == 733.0, "Test Failed: every waypoint, including rapids, should carry the cutting feed rate")
        }
    }

    @Test("Every arc waypoint of the helix sits at the compensated mill radius from the hole/boss center")
    func testHelixMaintainsConstantRadiusThroughout() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0) // tool radius 2.0
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -5.0)
        let center = (5.0, 7.0)
        let contour = circleContour(center: center, diameter: 20.0) // hole radius 10.0

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 20.0))

        let expectedRadius = 10.0 - 2.0
        // Waypoints 0-1 are the center entry (radius 0) and the last two (disengage +
        // retract) are back at center too -- everything from the wall-engage move
        // through the end of the closing lap should sit at exactly the compensated
        // mill radius.
        let waypoints = toolpaths[0].passes[0].waypoints
        for waypoint in waypoints[2..<(waypoints.count - 2)] {
            let dx = waypoint.position.x - center.0
            let dy = waypoint.position.y - center.1
            let radius = (dx * dx + dy * dy).squareRoot()
            #expect(abs(radius - expectedRadius) < 1e-9, "Test Failed: arc waypoint drifted off the compensated mill radius")
        }
    }

    @Test("The winding sense stays consistent across every turn of a multi-turn helix, not just the first")
    func testWindingSenseConsistentAcrossAllTurns() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -4.0)
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 10.0))

        let waypoints = toolpaths[0].passes[0].waypoints
        // Every arc waypoint (everything but the center entry, the wall-engage feed,
        // the center disengage, and the final retract) should keep winding CCW for a
        // right-hand thread mill, turn after turn.
        for waypoint in waypoints[3..<(waypoints.count - 2)] {
            if case .arcCCW = waypoint.motion {} else {
                Issue.record("Test Failed: winding sense flipped mid-helix, should stay .arcCCW throughout")
            }
        }
    }

    @Test("The output toolpath carries the same tool and settings the operation was generated with")
    func testOutputToolpathCarriesToolAndSettings() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -3.0)
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 10.0))

        #expect(toolpaths[0].tool == tool, "Test Failed: output toolpath should carry the exact tool used")
        #expect(toolpaths[0].settings == settings, "Test Failed: output toolpath should carry the exact settings used")
    }

    // Step 6.6: this used to assert that a batch mixing a good and a bad contour
    // skipped the bad one and still produced a toolpath for the good one. That's no
    // longer how batches behave once `.threadMilling` throws -- per `SCEngine.swift`'s
    // own doc comment on `generateToolpaths`, a thrown error now aborts the whole batch
    // rather than skipping just the offending contour, the same behavior change 6.2
    // introduced for `.drilling`. So this asserts the abort instead of a partial result.
    @Test("A batch mixing circle and non-circle contours throws on the first bad contour, aborting the whole batch")
    func testMixedBatchAbortsOnFirstBadContour() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0) // tool radius 1.5
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let goodContour = circleContour(center: (0, 0), diameter: 10.0) // hole radius 5.0
        let badContour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(20, 20), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        do {
            _ = try engine.generateToolpaths(from: [badContour, goodContour], tool: tool, settings: settings,
                                              operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 10.0))
            Issue.record("Test Failed: expected SC.Error.invalidContour to be thrown for the bad contour")
        } catch SC.Error.invalidContour {
            // expected -- the batch aborts before ever reaching the good contour
        } catch {
            Issue.record("Test Failed: expected SC.Error.invalidContour, got \(error)")
        }
    }

    // Calling per-contour instead of batching is how a caller gets the good contour's
    // toolpath despite a bad one elsewhere -- each call is independent, so one throwing
    // doesn't affect the other, unlike the single-call batch case above.
    @Test("Calling generateToolpaths per-contour still yields the good contour's toolpath despite a bad one elsewhere")
    func testPerContourCallsIsolateGoodContourFromBadOne() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0) // tool radius 1.5
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let goodContour = circleContour(center: (0, 0), diameter: 10.0) // hole radius 5.0
        let badContour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(20, 20), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let operation: SC.MachiningOperation = .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 10.0)

        var badContourThrew = false
        do {
            _ = try engine.generateToolpaths(from: [badContour], tool: tool, settings: settings, operation: operation)
        } catch SC.Error.invalidContour {
            badContourThrew = true
        }
        #expect(badContourThrew, "Test Failed: the bad contour should still throw invalidContour on its own")

        let goodToolpaths = try engine.generateToolpaths(from: [goodContour], tool: tool, settings: settings, operation: operation)
        #expect(goodToolpaths.count == 1, "Test Failed: the good contour should still produce a toolpath when called on its own")

        let millRadius = 5.0 - 1.5
        let entry = goodToolpaths[0].passes[0].waypoints[0]
        #expect(entry.position.x == 0.0 && entry.position.y == 0.0,
                "Test Failed: the surviving toolpath should still enter through the good contour's own hole center")

        let engage = goodToolpaths[0].passes[0].waypoints[2]
        #expect(abs(engage.position.x - millRadius) < 1e-9 && abs(engage.position.y) < 1e-9,
                "Test Failed: the surviving toolpath should still engage the good contour's hole at the compensated mill radius")
    }

    // MARK: - Radial passes (roughing out to the finished diameter)

    @Test("radialPasses controls how many full helical passes are produced")
    func testRadialPassesControlsPassCount() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -3.0)
        let contour = circleContour(center: (0, 0), diameter: 8.0) // existing (pre-drilled) hole diameter

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 3, targetDiameter: 10.0))

        #expect(toolpaths.count == 1, "Test Failed: expected 1 output toolpath")
        #expect(toolpaths[0].passes.count == 3, "Test Failed: expected 3 radial passes")
        for (index, pass) in toolpaths[0].passes.enumerated() {
            #expect(pass.passIndex == index, "Test Failed: pass \(index) should carry passIndex \(index)")
        }
    }

    @Test("Radial passes on an internal thread step outward from the existing hole, ending exactly on the target diameter")
    func testInternalRadialPassesStepOutwardToFinalDiameter() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0) // tool radius 1.5
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -3.0)
        // Existing (already-drilled) hole diameter 10.0 -- e.g. the pilot hole selected
        // in the CAM software -- stepping out to a 13.0mm target (finished) diameter.
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 3, targetDiameter: 13.0))

        let finalMillRadius = 13.0 / 2.0 - 1.5 // target radius - tool radius
        // Each pass's own engage waypoint (index 2) sits at that pass's radius --
        // radii should strictly increase pass over pass, with the last landing
        // exactly on the target diameter.
        var previousRadius = -Double.infinity
        for (index, pass) in toolpaths[0].passes.enumerated() {
            let engage = pass.waypoints[2]
            let radius = hypot(engage.position.x, engage.position.y)
            #expect(radius > previousRadius, "Test Failed: pass \(index) should engage farther out than the previous pass")
            previousRadius = radius
        }
        #expect(abs(previousRadius - finalMillRadius) < 1e-9, "Test Failed: the final pass should land exactly on the target diameter")
    }

    @Test("Radial passes on an external thread step inward from the existing boss, ending exactly on the target diameter")
    func testExternalRadialPassesStepInwardToFinalDiameter() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0) // tool radius 2.0
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)
        // Existing (already-turned) boss diameter 13.0, slightly oversized, stepping
        // down to a 12.0mm target (finished) diameter.
        let contour = circleContour(center: (0, 0), diameter: 13.0)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 2.0, isInternal: false, direction: .rightHand, radialPasses: 3, targetDiameter: 12.0))

        let finalMillRadius = 12.0 / 2.0 + 2.0 // target radius + tool radius
        var previousRadius = Double.infinity
        for (index, pass) in toolpaths[0].passes.enumerated() {
            let engage = pass.waypoints[2]
            let radius = hypot(engage.position.x, engage.position.y)
            #expect(radius < previousRadius, "Test Failed: pass \(index) should engage closer in than the previous pass")
            previousRadius = radius
        }
        #expect(abs(previousRadius - finalMillRadius) < 1e-9, "Test Failed: the final pass should land exactly on the target diameter")
    }

    @Test("A single radial pass lands directly on the target diameter, independent of the existing hole size")
    func testSingleRadialPassMatchesOriginalBehavior() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -3.0)
        // Deliberately a different diameter than the target -- with a single pass the
        // step covers the whole existing-to-target distance in one go, so the engage
        // radius should depend only on targetDiameter, not on this existing value.
        let contour = circleContour(center: (0, 0), diameter: 6.0)

        let toolpaths = try engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .threadMilling(pitch: 1.0, isInternal: true, direction: .rightHand, radialPasses: 1, targetDiameter: 10.0))

        #expect(toolpaths[0].passes.count == 1, "Test Failed: radialPasses: 1")
    }
}
