//
//  PocketSpiral.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 12.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

// Step 1B.1: `.spiral` pocketing. On a genuinely circular boundary it interpolates
// continuously between the ring stack's radii instead of chaining discrete rings; on
// anything else it falls back to the exact same ring-and-chain path `.offsetPattern`
// already uses (see `isSpiralEligible`'s doc comment for why detection is deliberately
// narrow -- circles only, not ellipses or "near-symmetrical" shapes).

struct PocketSpiral_Tests {

    // MARK: - Fixtures

    /// A circle centered at the origin -- the one boundary shape `.spiral` treats as
    /// eligible for a true continuous spiral. Matches how `SCEngine.swift` linearizes a
    /// DXF `.circle` entity (two 180° arcs of matching center/radius).
    private func circleContour(radius: Double) -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .circle(center: DXF.Point(0, 0), radius: radius, layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    /// A 20x10 CCW rectangle -- same fixture `Pocket_Tests.swift`/`PocketZPasses_Tests.swift`
    /// already use. Not circular, so `.spiral` must fall back on it.
    private func ccwRectangleContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 0), b: DXF.Point(20, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 10), b: DXF.Point(0, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, 10), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    private func pocketStrategy(pattern: SC.ClearingPattern, entry: SC.EntryStrategy = .plunge, direction: SC.CutDirection = .climb) -> SC.MachiningOperation {
        .pocket(direction: direction, pattern: pattern, entry: entry)
    }

    // MARK: - Continuous spiral on a circular boundary

    @Test("Spiral pocket interpolates continuously inward on a circular boundary, not in discrete ring jumps")
    func testSpiralPocketTracesContinuousInwardSpiralOnCircularBoundary() {
        let engine = SCEngine()
        // radius 10, 4mm tool (2mm radius), 50% stepover (2mm) -> rings at
        // radius 8, 6, 4, 2, same collapse rule `pocketRings` already uses elsewhere
        // (the next ring at 0 fails the >1e-6 check and stops the stack there).
        let tool = SC.ToolParams(diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                    plungeRate: 300.0,
                                                                    stepdown: 1.0,
                                                                    stepoverPercentage: 0.5),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [circleContour(radius: 10.0)],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .spiral)
        )

        #expect(toolpaths.count == 1, "Test Failed: expected 1 pocket toolpath")
        let waypoints = toolpaths[0].passes[0].waypoints

        // rapid + plunge + (4 rings x 72 steps/turn) + retract. 72 steps/turn is an
        // internal tessellation choice (5 degrees/step) -- if that constant ever
        // changes, this count is expected to move with it.
        #expect(waypoints.count == 2 + 4 * 72 + 1,
                "Test Failed: expected 291 waypoints (rapid, plunge, 288 spiral steps, retract), got \(waypoints.count)")

        func radius(_ waypoint: SC.Waypoint) -> Double {
            hypot(waypoint.position.x, waypoint.position.y)
        }

        // The plunge lands on the outermost ring's own start point (radius 8) --
        // same entry convention `.offsetPattern` uses.
        #expect(waypoints[0].position.z == 5.0, "Test Failed: expected the initial rapid at safeZ")
        #expect(abs(radius(waypoints[1]) - 8.0) < 1e-6, "Test Failed: plunge should land on the outermost ring's radius")
        #expect(waypoints[1].position.z == -1.0, "Test Failed: plunge should land at target depth")

        // Radius at each full-turn boundary matches that ring's own radius exactly --
        // proof the spiral is genuinely passing through the same rings `pocketRings`
        // computed, not some independently-derived curve.
        #expect(abs(radius(waypoints[73]) - 6.0) < 1e-6, "Test Failed: end of turn 1 should land exactly on ring 1's radius (6)")
        #expect(abs(radius(waypoints[145]) - 4.0) < 1e-6, "Test Failed: end of turn 2 should land exactly on ring 2's radius (4)")
        #expect(abs(radius(waypoints[217]) - 2.0) < 1e-6, "Test Failed: end of turn 3 should land exactly on ring 3's (innermost) radius (2)")

        // Midway through the first turn, the radius should sit halfway between ring 0
        // and ring 1 (8 -> 6, so 7) -- proof of genuine continuous interpolation
        // mid-turn, not a discrete jump that only happens to land correctly at the
        // turn boundaries checked above.
        #expect(abs(radius(waypoints[37]) - 7.0) < 1e-6,
                "Test Failed: expected the midpoint of turn 1 to be halfway between ring 0 and ring 1's radius")

        // The final turn is the "closes on itself" pass the `.spiral` case's own doc
        // comment describes -- it holds at the innermost radius rather than
        // interpolating toward anything further.
        #expect(abs(radius(waypoints[289]) - 2.0) < 1e-6,
                "Test Failed: expected the final turn to stay at the innermost ring's radius")

        // No two consecutive trace waypoints should ever jump by anywhere near a full
        // stepover (2mm) -- that's exactly the signature a discrete ring-and-chain
        // path would leave at each ring transition, and exactly what a true
        // continuous spiral must not do.
        var maxStep = 0.0
        for i in 2..<(waypoints.count - 2) {
            let a = waypoints[i].position
            let b = waypoints[i + 1].position
            maxStep = max(maxStep, hypot(b.x - a.x, b.y - a.y))
        }
        #expect(maxStep < 1.0, "Test Failed: expected small continuous steps, found a jump of \(maxStep) -- looks like a discrete ring transition")
    }

    @Test("Spiral pocket's geometry is reused unchanged across Z passes, same as offsetPattern")
    func testSpiralPocketGeometryReusedAcrossZPasses() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                    plungeRate: 300.0,
                                                                    stepdown: 1.0,
                                                                    stepoverPercentage: 0.5),
                                          safeZ: 5.0,
                                          targetDepth: -2.0)

        let toolpaths = engine.generateToolpaths(
            from: [circleContour(radius: 10.0)],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .spiral)
        )

        let passes = toolpaths[0].passes
        #expect(passes.count == 2, "Test Failed: expected 2 Z passes for a -2.0 depth at 1.0 stepdown")

        let firstPassWaypoints = passes[0].waypoints
        let secondPassWaypoints = passes[1].waypoints
        #expect(firstPassWaypoints.count == secondPassWaypoints.count,
                "Test Failed: the spiral geometry should be identical in shape across passes")

        for i in 0..<firstPassWaypoints.count {
            let a = firstPassWaypoints[i].position
            let b = secondPassWaypoints[i].position
            #expect(abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9,
                    "Test Failed: waypoint \(i)'s XY differs between passes -- spiral geometry should be computed once and reused")
        }
    }

    // MARK: - Fallback on a non-circular boundary

    @Test("Spiral pocket falls back to the exact offsetPattern ring-and-chain path on a non-circular boundary")
    func testSpiralPocketFallsBackToRingAndChainOnNonCircularBoundary() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let spiralWaypoints = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .spiral)
        )[0].passes[0].waypoints

        let offsetPatternWaypoints = engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .offsetPattern)
        )[0].passes[0].waypoints

        // A rectangle has no single center to spiral around, so `.spiral` should
        // produce the identical output `.offsetPattern` does -- not an attempt at a
        // spiral computed around the wrong point.
        #expect(spiralWaypoints == offsetPatternWaypoints,
                "Test Failed: expected .spiral to fall back to the exact .offsetPattern output on a non-circular boundary")
    }

    @Test("Spiral pocket falls back on a rounded rectangle too -- only a plain circle is eligible")
    func testSpiralPocketFallsBackOnRoundedRectangle() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        // A 20x10 rectangle with 2mm corner radii: some segments are arcs, but they
        // don't share one common center/radius the way a plain circle's do.
        let roundedRectangleContour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(2, 0), b: DXF.Point(18, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .arc(center: DXF.Point(18, 2), radius: 2.0, startDeg: -90, endDeg: 0, layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 2), b: DXF.Point(20, 8), layer: "0", color: 7), reversed: false),
            .init(entity: .arc(center: DXF.Point(18, 8), radius: 2.0, startDeg: 0, endDeg: 90, layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(18, 10), b: DXF.Point(2, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .arc(center: DXF.Point(2, 8), radius: 2.0, startDeg: 90, endDeg: 180, layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, 8), b: DXF.Point(0, 2), layer: "0", color: 7), reversed: false),
            .init(entity: .arc(center: DXF.Point(2, 2), radius: 2.0, startDeg: 180, endDeg: 270, layer: "0", color: 7), reversed: false)
        ], isClosed: true)

        let spiralWaypoints = engine.generateToolpaths(
            from: [roundedRectangleContour],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .spiral)
        )[0].passes[0].waypoints

        let offsetPatternWaypoints = engine.generateToolpaths(
            from: [roundedRectangleContour],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .offsetPattern)
        )[0].passes[0].waypoints

        #expect(spiralWaypoints == offsetPatternWaypoints,
                "Test Failed: a rounded rectangle has 4 different arc centers, not 1 -- .spiral should fall back here too")
    }
}
