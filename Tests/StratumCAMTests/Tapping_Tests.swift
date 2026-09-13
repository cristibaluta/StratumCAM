//
//  Tapping_Tests.swift
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
// into the helix's own winding sense, following the same climb/conventional convention
// `orientedForDirection` uses for wall cuts -- see `buildTappingToolpath`'s own doc
// comment on the exact mapping).
//
// The cut runs bottom-to-top and enters/exits through the hole's/boss's own center --
// see `buildTappingToolpath`'s doc comment for why -- so every waypoint-layout test
// below follows this fixed shape:
//   [0] Rapid to center @ SafeZ
//   [1] Rapid down center to the bottom of the thread
//   [2] Linear feed sideways to engage the wall at the mill radius, at the bottom
//   [3...]  n helical turns (ascending) + 1 flat closing lap at the top, 8 waypoints each
//   [count-2] Linear feed back to center, at the top, to disengage
//   [count-1] Rapid retract to SafeZ
// i.e. total waypoint count == 5 + (turnCount + 1) * 8, where turnCount is however many
// full-pitch (or one shortened, fencepost) revolutions `calculateZPasses` produces.

struct Tapping_Tests {

    /// Handy small helper: a closed circle contour marking a hole/boss of `diameter`,
    /// centered at `center` -- the same "closed circle marks the feature" shape
    /// `tapCircle(for:)` recognizes.
    private func circleContour(center: (Double, Double), diameter: Double) -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .circle(center: DXF.Point(center.0, center.1), radius: diameter / 2.0, layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    @Test("Thread milling enters/exits through center, cuts bottom-to-top, and finishes with a flat closing lap")
    func testThreadMillingEntersAndExitsThroughCenterCuttingBottomToTop() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0) // tool radius 1.5
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -3.0)

        let contour = circleContour(center: (0, 0), diameter: 10.0) // hole radius 5.0

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

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
        // Internal + climb winds CW (mirrors `.inside`'s own climb/conventional mapping
        // for wall cuts -- see Step 2D.2's coverage below for the other three combinations).
        if case .arcCW = endOfTurn1.motion {} else {
            Issue.record("Test Failed: internal threading milled with .climb should wind .arcCW")
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
    func testInternalThreadingOffsetsInward() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0) // tool radius 2.0
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = circleContour(center: (10, 20), diameter: 12.0) // hole radius 6.0

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 2.0, isInternal: true, direction: .climb))

        // waypoints[2] is the wall-engage move -- the first waypoint actually offset to
        // the compensated mill radius (waypoints 0-1 are the center entry).
        let engage = toolpaths[0].passes[0].waypoints[2]
        // Expected mill radius: 6.0 - 2.0 = 4.0, offset from the hole's own center.
        #expect(abs(engage.position.x - (10.0 + 4.0)) < 1e-9 && abs(engage.position.y - 20.0) < 1e-9,
                "Test Failed: internal threading should orbit inside the drawn diameter by the tool's radius")
    }

    @Test("External threading compensates the mill radius outward from the boss's diameter")
    func testExternalThreadingOffsetsOutward() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0) // tool radius 2.0
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = circleContour(center: (10, 20), diameter: 12.0) // boss radius 6.0

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 2.0, isInternal: false, direction: .climb))

        let engage = toolpaths[0].passes[0].waypoints[2]
        // Expected mill radius: 6.0 + 2.0 = 8.0, offset from the boss's own center.
        #expect(abs(engage.position.x - (10.0 + 8.0)) < 1e-9 && abs(engage.position.y - 20.0) < 1e-9,
                "Test Failed: external threading should orbit outside the drawn diameter by the tool's radius")
    }

    @Test("Thread milling a hole not much bigger than the tool itself produces no toolpath")
    func testToolTooLargeForInternalHoleReturnsNoToolpath() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 10.0) // tool radius 5.0
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = circleContour(center: (0, 0), diameter: 8.0) // hole radius 4.0, smaller than the tool radius

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

        #expect(toolpaths.isEmpty, "Test Failed: a tool wider than the hole radius shouldn't produce a thread-milling toolpath")
    }

    @Test("A non-circle contour produces no tapping toolpath")
    func testNonCircleContourReturnsNoToolpath() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

        #expect(toolpaths.isEmpty, "Test Failed: tapping needs a diameter to compensate against, so a bare point shouldn't produce a toolpath")
    }

    @Test("A zero pitch produces no toolpath")
    func testZeroPitchReturnsNoToolpath() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 0.0, isInternal: true, direction: .climb))

        #expect(toolpaths.isEmpty, "Test Failed: a zero pitch has no well-defined helix and shouldn't produce a toolpath")
    }

    // MARK: - Winding direction (Step 2D.2)

    /// Reads the winding sense off the first arc waypoint (index 3 -- right after the
    /// two setup rapids to center and the linear wall-engage move) for a single-turn
    /// thread mill, so each case below only needs to check one waypoint rather than
    /// re-deriving the full waypoint layout.
    private func firstArcIsCCW(isInternal: Bool, direction: SC.CutDirection) -> Bool {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -1.0)
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: isInternal, direction: direction))

        guard case .arcCCW = toolpaths[0].passes[0].waypoints[3].motion else {
            return false
        }
        return true
    }

    @Test("Internal threading milled climb winds CW, the same as an .inside wall cut")
    func testInternalClimbWindsCW() {
        #expect(firstArcIsCCW(isInternal: true, direction: .climb) == false,
                "Test Failed: internal + climb should wind CW")
    }

    @Test("Internal threading milled conventional winds CCW, the same as an .inside wall cut")
    func testInternalConventionalWindsCCW() {
        #expect(firstArcIsCCW(isInternal: true, direction: .conventional) == true,
                "Test Failed: internal + conventional should wind CCW")
    }

    @Test("External threading milled climb winds CCW, the same as an .outside cut")
    func testExternalClimbWindsCCW() {
        #expect(firstArcIsCCW(isInternal: false, direction: .climb) == true,
                "Test Failed: external + climb should wind CCW")
    }

    @Test("External threading milled conventional winds CW, the same as an .outside cut")
    func testExternalConventionalWindsCW() {
        #expect(firstArcIsCCW(isInternal: false, direction: .conventional) == false,
                "Test Failed: external + conventional should wind CW")
    }

    @Test("Tapping a batch of holes assigns each toolpath to its own hole location")
    func testTappingBatchOfHolesEachGetsOwnToolpath() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0) // tool radius 1.5
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let centers: [(Double, Double)] = [(0, 0), (20, 0), (20, 20), (0, 20)]
        let contours = centers.map { circleContour(center: $0, diameter: 10.0) } // hole radius 5.0

        let toolpaths = engine.generateToolpaths(from: contours, tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

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
    func testNegativePitchTreatedAsMagnitude() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -3.0)
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let positive = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))
        let negative = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                 operation: .tapping(pitch: -1.0, isInternal: true, direction: .climb))

        #expect(negative.count == 1, "Test Failed: a negative pitch should still produce a toolpath")
        #expect(positive[0].passes[0].waypoints.count == negative[0].passes[0].waypoints.count,
                "Test Failed: negative pitch should produce the same waypoint layout as its positive magnitude")
        for (pw, nw) in zip(positive[0].passes[0].waypoints, negative[0].passes[0].waypoints) {
            #expect(abs(pw.position.z - nw.position.z) < 1e-9, "Test Failed: negative pitch should step identically to its magnitude")
        }
    }

    @Test("A target depth that isn't an exact multiple of pitch places its shortened turn at the bottom instead of overshooting")
    func testPartialFinalTurnDepthDoesNotOvershoot() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -3.5)
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

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
    func testSingleShortTurnWhenDepthLessThanPitch() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -0.5)
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

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
    func testAllWaypointsUseCuttingFeedRate() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 733.0, plungeRate: 150.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -3.0)
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

        for waypoint in toolpaths[0].passes[0].waypoints {
            #expect(waypoint.feedRate == 733.0, "Test Failed: every waypoint, including rapids, should carry the cutting feed rate")
        }
    }

    @Test("Every arc waypoint of the helix sits at the compensated mill radius from the hole/boss center")
    func testHelixMaintainsConstantRadiusThroughout() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0) // tool radius 2.0
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -5.0)
        let center = (5.0, 7.0)
        let contour = circleContour(center: center, diameter: 20.0) // hole radius 10.0

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

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
    func testWindingSenseConsistentAcrossAllTurns() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -4.0)
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

        let waypoints = toolpaths[0].passes[0].waypoints
        // Every arc waypoint (everything but the center entry, the wall-engage feed,
        // the center disengage, and the final retract) should keep winding CW for an
        // internal + climb thread mill, turn after turn.
        for waypoint in waypoints[3..<(waypoints.count - 2)] {
            if case .arcCW = waypoint.motion {} else {
                Issue.record("Test Failed: winding sense flipped mid-helix, should stay .arcCW throughout")
            }
        }
    }

    @Test("The output toolpath carries the same tool and settings the operation was generated with")
    func testOutputToolpathCarriesToolAndSettings() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -3.0)
        let contour = circleContour(center: (0, 0), diameter: 10.0)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

        #expect(toolpaths[0].tool == tool, "Test Failed: output toolpath should carry the exact tool used")
        #expect(toolpaths[0].settings == settings, "Test Failed: output toolpath should carry the exact settings used")
    }

    @Test("A batch mixing circle and non-circle contours only produces toolpaths for the circles")
    func testMixedBatchOnlyCirclesProduceToolpaths() {
        let engine = SCEngine()
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0) // tool radius 1.5
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let goodContour = circleContour(center: (0, 0), diameter: 10.0) // hole radius 5.0
        let badContour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(20, 20), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = engine.generateToolpaths(from: [badContour, goodContour], tool: tool, settings: settings,
                                                  operation: .tapping(pitch: 1.0, isInternal: true, direction: .climb))

        #expect(toolpaths.count == 1, "Test Failed: only the circle contour should yield a tapping toolpath")

        let millRadius = 5.0 - 1.5
        let entry = toolpaths[0].passes[0].waypoints[0]
        #expect(entry.position.x == 0.0 && entry.position.y == 0.0,
                "Test Failed: the surviving toolpath should still enter through the good contour's own hole center")

        let engage = toolpaths[0].passes[0].waypoints[2]
        #expect(abs(engage.position.x - millRadius) < 1e-9 && abs(engage.position.y) < 1e-9,
                "Test Failed: the surviving toolpath should still engage the good contour's hole at the compensated mill radius")
    }
}
