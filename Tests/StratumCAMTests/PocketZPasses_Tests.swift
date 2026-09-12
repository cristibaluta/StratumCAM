//
//  PocketZPasses.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 12.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

// Pockets now step down through Z the same way `.contour` does, reusing
// `calculateZPasses` and threading `previousZ` into ramp/helix entry so each pass only
// covers its own fresh stepdown. These tests cover: correct pass count/depths for both
// pattern types, that the ring/raster geometry itself is computed once and reused
// unchanged across passes (not regenerated), and that ramp/helix entries on a later
// pass start from the previous pass's depth rather than re-descending from top-of-stock
// every time.

struct PocketZPasses_Tests {

    // MARK: - Fixtures

    /// A 20x10 CCW rectangle. With a 6mm tool (3mm radius) the `.offsetPattern` wall
    /// offset lands at [3, 17] x [3, 7], and `.climb` orients the ring to start at the
    /// inward bottom-left corner (3, 3) traveling upward to (3, 7) first -- same fixture
    /// `Pocket_Tests.swift`/`PocketEntry_Tests.swift` already rely on.
    private func ccwRectangleContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 0), b: DXF.Point(20, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 10), b: DXF.Point(0, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, 10), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    private func pocketStrategy(pattern: SC.ClearingPattern, entry: SC.EntryStrategy, direction: SC.CutDirection = .climb) -> SC.MachiningOperation {
        .pocket(direction: direction, pattern: pattern, entry: entry)
    }

    // MARK: - Pass count / depths

    @Test("Pocket honors calculateZPasses for an unevenly divisible depth")
    func testPocketMultiPassZDepthsMatchCalculateZPasses() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        // -2.5 / 1.0 -> rounds up to 3 passes: -1.0, -2.0, -2.5 (same fencepost rule
        // `calculateZPasses` already covers in ZPasses_Tests.swift).
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -2.5)

        let toolpaths = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .offsetPattern, entry: .plunge)
        )

        #expect(toolpaths.count == 1, "Test Failed: expected 1 pocket toolpath")
        let passes = toolpaths[0].passes

        #expect(passes.count == 3, "Test Failed: expected 3 Z passes, got \(passes.count)")
        #expect(passes[0].depthZ == -1.0, "Test Failed: pass 0 depth mismatch")
        #expect(passes[1].depthZ == -2.0, "Test Failed: pass 1 depth mismatch")
        #expect(passes[2].depthZ == -2.5, "Test Failed: pass 2 should land exactly on target depth")

        // Single ring (6mm tool) with plunge entry -> rapid, plunge, 4 ring corners,
        // retract per pass, same waypoint shape every time -- only the Z changes.
        for pass in passes {
            #expect(pass.waypoints.count == 7, "Test Failed: expected 7 waypoints per pass, got \(pass.waypoints.count)")
            #expect(pass.waypoints[1].position.z == pass.depthZ, "Test Failed: plunge should land at this pass's own depth")
        }
    }

    @Test("Raster pocket also gets multi-pass Z stepdown, not just offsetPattern")
    func testRasterPocketAlsoGetsMultiPassZStepdown() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                    plungeRate: 300.0,
                                                                    stepdown: 1.0,
                                                                    stepoverPercentage: 0.5),
                                          safeZ: 5.0,
                                          targetDepth: -2.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .raster, entry: .plunge)
        )

        let passes = toolpaths[0].passes
        #expect(passes.count == 2, "Test Failed: expected 2 raster Z passes, got \(passes.count)")
        #expect(passes[0].depthZ == -1.0, "Test Failed: raster pass 0 depth mismatch")
        #expect(passes[1].depthZ == -2.0, "Test Failed: raster pass 1 depth mismatch")

        // The first raster row still starts at the same wall-offset corner (3, 3) on
        // every pass -- the scanline geometry wasn't regenerated per pass.
        for pass in passes {
            let plunge = pass.waypoints[1]
            #expect(abs(plunge.position.x - 3.0) < 1e-5 && abs(plunge.position.y - 3.0) < 1e-5,
                    "Test Failed: expected every pass's first row to start at the same (3, 3) corner")
        }
    }

    // MARK: - Geometry reused, not regenerated, across passes

    @Test("Pocket ring geometry is computed once and reused unchanged across every Z pass")
    func testPocketRingGeometryIsReusedAcrossZPasses() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0)
        // 4mm tool, 50% stepover -> 2 rings, same fixture as
        // `Pocket_Tests.testPocketChainsMultipleRingsIntoOnePass`.
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                    plungeRate: 300.0,
                                                                    stepdown: 1.0,
                                                                    stepoverPercentage: 0.5),
                                          safeZ: 5.0,
                                          targetDepth: -2.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .offsetPattern, entry: .plunge)
        )

        let passes = toolpaths[0].passes
        #expect(passes.count == 2, "Test Failed: expected 2 Z passes for a -2.0 depth at 1.0 stepdown")

        let firstPassWaypoints = passes[0].waypoints
        let secondPassWaypoints = passes[1].waypoints

        #expect(firstPassWaypoints.count == 12, "Test Failed: expected 12 waypoints for the 2-ring chained pass")
        #expect(secondPassWaypoints.count == firstPassWaypoints.count,
                "Test Failed: every pass should trace the identical ring geometry, so waypoint counts must match")

        // Same XY at every index across both passes -- if the geometry were being
        // regenerated per pass instead of reused, drift here would be the tell.
        for i in 0..<firstPassWaypoints.count {
            let a = firstPassWaypoints[i].position
            let b = secondPassWaypoints[i].position
            #expect(abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9,
                    "Test Failed: waypoint \(i)'s XY differs between passes -- ring geometry should be identical")
        }

        // Only the Z at cutting depth differs between passes; the safeZ rapid/retract
        // bookends stay put.
        #expect(firstPassWaypoints[0].position.z == secondPassWaypoints[0].position.z, "Test Failed: initial rapid Z should match safeZ on every pass")
        #expect(firstPassWaypoints[1].position.z == -1.0 && secondPassWaypoints[1].position.z == -2.0,
                "Test Failed: each pass's plunge should land at its own depth")
    }

    // MARK: - Ramp/helix entry: previousZ threading

    @Test("Pocket ramp entry on a later pass starts from the previous pass's depth, not top-of-stock")
    func testPocketRampEntryStartsFromPreviousPassDepth() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        // stepdown 1.0 over a target of -2.0 -> two passes: -1.0, then -2.0.
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -2.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .offsetPattern, entry: .ramp(angleDegrees: 30))
        )

        let passes = toolpaths[0].passes
        #expect(passes.count == 2, "Test Failed: expected 2 passes")

        // Pass 0 ramps the fresh 0 -> -1.0 stepdown: first leg partway down at -0.5,
        // second leg lands exactly on the ring start at -1.0.
        let firstPassWaypoints = passes[0].waypoints
        #expect(abs(firstPassWaypoints[1].position.z - (-0.5)) < 1e-6,
                "Test Failed: pass 0's first ramp leg should be halfway through its 0 -> -1.0 stepdown")
        #expect(abs(firstPassWaypoints[2].position.z - (-1.0)) < 1e-6,
                "Test Failed: pass 0's ramp should land exactly at -1.0")

        // Pass 1 should ramp the fresh -1.0 -> -2.0 stepdown -- i.e. start from where
        // pass 0 left off, not re-descend the whole 0 -> -2.0 span. If `previousZ`
        // weren't threaded through, this first leg would incorrectly land at -0.5
        // (the same as pass 0's) instead of -1.5.
        let secondPassWaypoints = passes[1].waypoints
        #expect(abs(secondPassWaypoints[1].position.z - (-1.5)) < 1e-6,
                "Test Failed: pass 1's first ramp leg should be halfway through its -1.0 -> -2.0 stepdown, not restarting from top-of-stock")
        #expect(abs(secondPassWaypoints[2].position.z - (-2.0)) < 1e-6,
                "Test Failed: pass 1's ramp should land exactly at -2.0")

        // Neither pass should ever cut past its own target depth.
        #expect(!firstPassWaypoints.contains { $0.position.z < -1.0 - 1e-9 },
                "Test Failed: pass 0 should never cut deeper than -1.0")
        #expect(!secondPassWaypoints.contains { $0.position.z < -2.0 - 1e-9 },
                "Test Failed: pass 1 should never cut deeper than -2.0")
    }

    @Test("Pocket helix entry on a later pass only spirals through its own fresh stepdown")
    func testPocketHelixEntryStartsFromPreviousPassDepth() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -2.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .offsetPattern, entry: .helix(radius: 1.0, rampAngleDegrees: 30))
        )

        let passes = toolpaths[0].passes
        #expect(passes.count == 2, "Test Failed: expected 2 passes")

        let secondPassWaypoints = passes[1].waypoints

        // Every waypoint in pass 1 apart from the initial safeZ rapid and the final
        // safeZ retract must stay at or below the previous pass's depth (-1.0) -- if
        // the helix were still spiraling down from top-of-stock (the pre-1.3 bug),
        // its early turns would pass back through depths shallower than -1.0.
        let entryAndTrace = secondPassWaypoints.dropFirst().dropLast()
        #expect(!entryAndTrace.contains { $0.position.z > -1.0 + 1e-9 },
                "Test Failed: pass 1's helix/trace should never be shallower than the previous pass's depth (-1.0)")

        // It should still faithfully reach the full target depth by the end of the entry.
        let landsAtTarget = secondPassWaypoints.contains { abs($0.position.z - (-2.0)) < 1e-6 }
        #expect(landsAtTarget, "Test Failed: pass 1 should still reach the full -2.0 target depth")
    }

    @Test("Pocket plunge entry is unaffected by multi-pass Z stepdown -- still a straight rapid + plunge per pass")
    func testPocketPlungeEntryStillStraightDownPerPass() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -2.0)

        let toolpaths = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .offsetPattern, entry: .plunge)
        )

        let passes = toolpaths[0].passes
        #expect(passes.count == 2, "Test Failed: expected 2 passes")

        for pass in passes {
            // rapid + plunge + 4 ring corners + retract, same shape every pass.
            #expect(pass.waypoints.count == 7, "Test Failed: expected the untouched plunge-entry waypoint count per pass")

            let wp0 = pass.waypoints[0]
            #expect(wp0.position.z == 5.0, "Test Failed: each pass should still rapid from safeZ, not the previous pass's depth")
            if case .rapid = wp0.motion {} else {
                Issue.record("Test Failed: first waypoint motion must be .rapid")
            }

            let wp1 = pass.waypoints[1]
            #expect(wp1.position.z == pass.depthZ, "Test Failed: plunge entry should still land straight down at this pass's own depth")
            if case .linear = wp1.motion {} else {
                Issue.record("Test Failed: plunge entry's second waypoint motion must be .linear")
            }
        }
    }
}
