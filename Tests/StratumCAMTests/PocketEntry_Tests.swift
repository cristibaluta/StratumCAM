//
//  PocketEntry.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 12.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

// Pocket's first plunge point should honor `EntryStrategy` (plunge/ramp/helix)
// the same way `.contour` already does, for both `.offsetPattern` and `.raster`. These
// tests cover the ramp/helix entry moves specifically -- `.plunge` behavior itself is
// already covered by `Pocket_Tests.swift`

struct PocketEntry_Tests {

    // MARK: - Fixtures

    /// A 20x10 CCW rectangle. With a 6mm tool (3mm radius) the `.offsetPattern` wall
    /// offset lands at [3, 17] x [3, 7], and `.climb` orients the ring to start at the
    /// inward bottom-left corner (3, 3) -- same fixture and geometry `Pocket_Tests.swift`
    /// already relies on.
    private func ccwRectangleContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 0), b: DXF.Point(20, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 10), b: DXF.Point(0, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, 10), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    private func pocketStrategy(pattern: SC.PocketClearingPattern, entry: SC.EntryStrategy, direction: SC.CutDirection = .climb) -> SC.MachiningOperation {
        .pocket(direction: direction, pattern: pattern, entry: entry)
    }

    private func isArcMotion(_ motion: SC.MotionType) -> Bool {
        if case .arcCW = motion { return true }
        if case .arcCCW = motion { return true }
        return false
    }

    // MARK: - offsetPattern: ramp entry

    @Test("Pocket ramp entry descends from top-of-stock and lands on the ring start at depth")
    func testPocketRampEntryLandsOnRingStartAtDepth() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .offset, entry: .ramp(angleDegrees: 30))
        )

        #expect(toolpaths.count == 1, "Test Failed: expected 1 pocket toolpath")
        let waypoints = toolpaths[0].passes[0].waypoints

        // [0] Rapid above the ring start (3, 3) @ SafeZ -- the ramp itself only needs to
        // handle the safeZ -> target descent since pocketing is still single-pass (1.3).
        let wp0 = waypoints[0]
        #expect(abs(wp0.position.x - 3.0) < 1e-5 && abs(wp0.position.y - 3.0) < 1e-5 && wp0.position.z == 5.0,
                "Test Failed: initial rapid move should be above the ring start corner")
        if case .rapid = wp0.motion {} else {
            Issue.record("Test Failed: first waypoint motion must be .rapid")
        }

        // A ramp always finishes back exactly on the ring's start point at target depth,
        // ready to hand off into the ring trace -- same guarantee `.contour`'s ramp gives.
        let landsAtTarget = waypoints.contains { wp in
            abs(wp.position.x - 3.0) < 1e-6 && abs(wp.position.y - 3.0) < 1e-6 && abs(wp.position.z - (-1.0)) < 1e-6
        }
        #expect(landsAtTarget, "Test Failed: expected the ramp to land back on the ring start at target depth")

        // No ramp waypoint should ever go past target depth.
        let overshoots = waypoints.contains { $0.position.z < -1.0 - 1e-9 }
        #expect(!overshoots, "Test Failed: ramp should never cut deeper than target depth")

        // The ring itself still gets traced afterwards -- the far corner (17, 7) should
        // appear at full target depth just like the plunge-entry case does.
        let tracesRing = waypoints.contains { wp in
            abs(wp.position.x - 17.0) < 1e-5 && abs(wp.position.y - 7.0) < 1e-5 && abs(wp.position.z - (-1.0)) < 1e-6
        }
        #expect(tracesRing, "Test Failed: expected the ring to still be traced after the ramp entry")

        // Final waypoint retracts to safeZ.
        #expect(waypoints.last?.position.z == 5.0, "Test Failed: expected the final retract to safeZ")
    }

    @Test("Pocket ramp entry travel distance matches the requested angle, not a whole ring edge")
    func testPocketRampEntryDistanceMatchesAngle() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        // A shallow 0.1mm target depth at 30 degrees only needs a fraction of a mm of
        // horizontal travel -- nowhere near the 4mm-tall ring wall it's anchored to.
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 0.1),
                                          safeZ: 5.0,
                                          targetDepth: -0.1)

        let toolpaths = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .offset, entry: .ramp(angleDegrees: 30))
        )

        let waypoints = toolpaths[0].passes[0].waypoints

        // wp0 = rapid @ safeZ above (3,3), wp1 = the first ramp leg.
        let firstRampLeg = waypoints[1]
        let travelDistance = abs(firstRampLeg.position.y - 3.0)

        #expect(travelDistance < 1.0,
                "Test Failed: a 0.1mm target depth at 30 degrees should only travel a fraction of a mm, not swing across the whole ring wall")
    }

    // MARK: - offsetPattern: helix entry

    @Test("Pocket helix entry spirals down and returns to the ring start at depth")
    func testPocketHelixEntryReturnsToRingStartAtDepth() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .offset, entry: .helix(radius: 1.0, rampAngleDegrees: 30))
        )

        let waypoints = toolpaths[0].passes[0].waypoints

        let wp0 = waypoints[0]
        #expect(abs(wp0.position.x - 3.0) < 1e-5 && abs(wp0.position.y - 3.0) < 1e-5 && wp0.position.z == 5.0,
                "Test Failed: initial rapid move should be above the ring start corner")

        // A helix always completes a whole number of turns, so somewhere in the entry
        // phase it must land back exactly on the ring's start point at target depth.
        let landsAtTarget = waypoints.contains { wp in
            abs(wp.position.x - 3.0) < 1e-6 && abs(wp.position.y - 3.0) < 1e-6 && abs(wp.position.z - (-1.0)) < 1e-6
        }
        #expect(landsAtTarget, "Test Failed: expected helix entry to land back on the ring start at target depth")

        // The spiral itself should be made of arc moves, not linear jumps.
        let hasArcEntryMoves = waypoints.contains { isArcMotion($0.motion) }
        #expect(hasArcEntryMoves, "Test Failed: expected helix entry to generate arc motion waypoints")
    }

    @Test("Pocket helix entry never cuts below target depth while spiraling down")
    func testPocketHelixEntryNeverOvershootsDepth() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .offset, entry: .helix(radius: 1.0, rampAngleDegrees: 30))
        )

        let waypoints = toolpaths[0].passes[0].waypoints
        let overshoots = waypoints.contains { $0.position.z < -1.0 - 1e-9 }
        #expect(!overshoots, "Test Failed: helix entry should never cut deeper than target depth")
    }

    // MARK: - raster: entry integration

    @Test("Raster pocket also honors ramp entry, not just offsetPattern")
    func testRasterPocketHonorsRampEntry() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
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
            operation: pocketStrategy(pattern: .raster, entry: .ramp(angleDegrees: 30))
        )

        #expect(toolpaths.count == 1, "Test Failed: expected 1 raster pocket toolpath")
        let waypoints = toolpaths[0].passes[0].waypoints

        // Raster's first row starts at the wall-offset boundary's bottom-left corner
        // (3, 3), same wall offset the offsetPattern ring stack starts from.
        let wp0 = waypoints[0]
        #expect(abs(wp0.position.x - 3.0) < 1e-5 && abs(wp0.position.y - 3.0) < 1e-5 && wp0.position.z == 5.0,
                "Test Failed: initial rapid move should be above the first raster row's start")

        let landsAtTarget = waypoints.contains { wp in
            abs(wp.position.x - 3.0) < 1e-6 && abs(wp.position.y - 3.0) < 1e-6 && abs(wp.position.z - (-1.0)) < 1e-6
        }
        #expect(landsAtTarget, "Test Failed: expected the ramp to land back on the first row's start at target depth")

        // The first raster row is still cut afterwards -- (17, 3) should show up at
        // full target depth, same as the un-entered raster case would produce.
        let tracesFirstRow = waypoints.contains { wp in
            abs(wp.position.x - 17.0) < 1e-5 && abs(wp.position.y - 3.0) < 1e-5 && abs(wp.position.z - (-1.0)) < 1e-6
        }
        #expect(tracesFirstRow, "Test Failed: expected the first raster row to still be traced after the ramp entry")
    }

    @Test("Raster pocket also honors helix entry, not just offsetPattern")
    func testRasterPocketHonorsHelixEntry() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
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
            operation: pocketStrategy(pattern: .raster, entry: .helix(radius: 1.0, rampAngleDegrees: 30))
        )

        let waypoints = toolpaths[0].passes[0].waypoints

        let landsAtTarget = waypoints.contains { wp in
            abs(wp.position.x - 3.0) < 1e-6 && abs(wp.position.y - 3.0) < 1e-6 && abs(wp.position.z - (-1.0)) < 1e-6
        }
        #expect(landsAtTarget, "Test Failed: expected helix entry to land back on the first row's start at target depth")

        let hasArcEntryMoves = waypoints.contains { isArcMotion($0.motion) }
        #expect(hasArcEntryMoves, "Test Failed: expected helix entry to generate arc motion waypoints")
    }

    // MARK: - Regression: raster helix entry must not exceed the pocket's own bounds

    /// A 40x24 CCW rectangle -- large enough, and with a large enough stepover, that
    /// `.raster` produces several scan rows, which is what exposed the bug: computing
    /// the helix's offset side from the raster's own (open, direction-alternating) row
    /// chain instead of the closed wall boundary produced an arbitrary sign, so some
    /// helix entries spiraled outward through the wall instead of staying inside it.
    private func wideRasterContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(40, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(40, 0), b: DXF.Point(40, 24), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(40, 24), b: DXF.Point(0, 24), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, 24), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    @Test("Raster helix entry never spirals past the pocket's own wall-offset boundary")
    func testRasterHelixEntryStaysWithinStockBoundary() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                    plungeRate: 300.0,
                                                                    stepdown: 1.0,
                                                                    stepoverPercentage: 0.4),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [wideRasterContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .raster, entry: .helix(radius: 2.0, rampAngleDegrees: 30))
        )

        #expect(toolpaths.count == 1, "Test Failed: expected 1 raster pocket toolpath")
        let waypoints = toolpaths[0].passes[0].waypoints

        // The real limit that matters is the wall-offset boundary the raster rows are
        // clipped to -- [3, 37] x [3, 21] for a 40x24 rectangle with a 6mm (3mm-radius)
        // tool -- not the outer [0, 40] x [0, 24] stock rectangle. A helix that only
        // overshoots by up to its own radius (2mm here) can still land comfortably
        // inside the stock while cutting well outside the raster's own boundary, which
        // is exactly the bug: checking against the stock rectangle alone would not have
        // caught it.
        let wallMinX = 3.0, wallMaxX = 37.0, wallMinY = 3.0, wallMaxY = 21.0
        let outOfBounds = waypoints.first { wp in
            wp.position.x < wallMinX - 1e-6 || wp.position.x > wallMaxX + 1e-6 ||
            wp.position.y < wallMinY - 1e-6 || wp.position.y > wallMaxY + 1e-6
        }
        #expect(outOfBounds == nil,
                "Test Failed: expected every waypoint to stay within the [3, 37] x [3, 21] wall-offset boundary, found \(String(describing: outOfBounds?.position))")
    }

    // MARK: - Regression: plunge entry stays untouched

    @Test("Pocket plunge entry is unaffected by Step 1.2 -- still a straight rapid + plunge")
    func testPocketPlungeEntryStillStraightDown() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .offset, entry: .plunge)
        )

        let waypoints = toolpaths[0].passes[0].waypoints

        // rapid + plunge + 4 ring corners + retract, exactly as before Step 1.2.
        #expect(waypoints.count == 7, "Test Failed: expected the untouched plunge-entry waypoint count")

        let wp1 = waypoints[1]
        #expect(abs(wp1.position.x - 3.0) < 1e-5 && abs(wp1.position.y - 3.0) < 1e-5 && wp1.position.z == -1.0,
                "Test Failed: plunge entry should still land straight down on the ring start at full depth")
        if case .linear = wp1.motion {} else {
            Issue.record("Test Failed: plunge entry's second waypoint motion must be .linear")
        }
    }
}
