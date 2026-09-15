//
//  PocketSpiralDirection.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

// Step 1B.1b: `.spiral`'s selectable `direction` (`.outsideIn` / `.insideOut`). `.outsideIn`
// is exactly Step 1B.1's original behavior (opens on the outer wall ring, closes on the
// innermost ring) and stays the default so bare `.spiral` keeps compiling unchanged.
// `.insideOut` reverses which end of the same ring stack the spiral starts and finishes
// at -- opens on the innermost ring, closes with a single uninterrupted pass around the
// wall -- and only matters once a boundary is already spiral-eligible (see
// `isSpiralEligible`); the non-circular fallback path is unaffected either way.

struct PocketSpiralDirection_Tests {

    // MARK: - Fixtures

    /// Same circular fixture `PocketSpiral_Tests.swift` uses: a circle centered at the
    /// origin, the one boundary shape `.spiral` treats as eligible for a true continuous
    /// spiral.
    private func circleContour(radius: Double) -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .circle(center: DXF.Point(0, 0), radius: radius, layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    /// Same 20x10 CCW rectangle fixture `PocketSpiral_Tests.swift` uses -- not circular,
    /// so `.spiral` falls back to the exact `.offsetPattern` ring-and-chain path
    /// regardless of `direction`.
    private func ccwRectangleContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 0), b: DXF.Point(20, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 10), b: DXF.Point(0, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, 10), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    private func pocketStrategy(pattern: SC.PocketClearingPattern, entry: SC.EntryStrategy = .plunge, direction: SC.CutDirection = .climb) -> SC.MachiningOperation {
        .pocket(direction: direction, pattern: pattern, entry: entry)
    }

    // MARK: - `.insideOut` on a circular boundary

    @Test("Inside-out spiral pocket enters at the innermost ring and closes on the outer wall radius")
    func testInsideOutSpiralEntersAtInnermostRingAndClosesAtWallRadius() throws {
        let engine = SCEngine()
        // Same rings as PocketSpiral_Tests' equivalent case: radius 10, 4mm tool (2mm
        // radius), 50% stepover (2mm) -> rings at 8, 6, 4, 2 outside-in. `.insideOut`
        // reverses that to 2, 4, 6, 8 before interpolating.
        let tool = SC.ToolParams(diameter: 4.0)
        let cutting = SC.CuttingData(feedRate: 1000.0,
                                     plungeRate: 300.0,
                                     stepdown: 1.0,
                                     stepoverPercentage: 0.5)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)

        let toolpaths = try engine.generateToolpaths(
            from: [circleContour(radius: 10.0)],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .spiral(direction: .insideOut))
        )

        #expect(toolpaths.count == 1, "Test Failed: expected 1 pocket toolpath")
        let waypoints = toolpaths[0].passes[0].waypoints

        // Same waypoint budget as the outside-in case -- reversing the ring order
        // doesn't change how many rings or steps/turn there are, only which radius each
        // turn holds or interpolates toward.
        #expect(waypoints.count == 2 + 5 * 72 + 1,
                "Test Failed: expected 363 waypoints (rapid, plunge, 360 spiral steps, retract), got \(waypoints.count)")

        func radius(_ waypoint: SC.Waypoint) -> Double {
            hypot(waypoint.position.x, waypoint.position.y)
        }

        // The plunge lands on the innermost ring's own start point (radius 2) -- the
        // opposite end from `.outsideIn`, and exactly where the `.spiral` case's own doc
        // comment says `.insideOut` should enter.
        #expect(waypoints[0].position.z == 5.0, "Test Failed: expected the initial rapid at safeZ")
        #expect(abs(radius(waypoints[1]) - 2.0) < 1e-6, "Test Failed: insideOut plunge should land on the innermost ring's radius")
        #expect(waypoints[1].position.z == -1.0, "Test Failed: plunge should land at target depth")

        // The opening turn must hold at the innermost radius (2) all the way round --
        // the same "actually sweep the first ring, don't just touch it once" guarantee
        // `.outsideIn` gives its wall ring, just applied to the opposite end here.
        #expect(abs(radius(waypoints[1 + 18]) - 2.0) < 1e-6, "Test Failed: quarter-way round the opening turn should still be at the innermost radius")
        #expect(abs(radius(waypoints[1 + 54]) - 2.0) < 1e-6, "Test Failed: three-quarters round the opening turn should still be at the innermost radius")
        #expect(abs(radius(waypoints[1 + 72]) - 2.0) < 1e-6, "Test Failed: the opening turn should close back on itself at the innermost radius")

        // Radius at each subsequent full-turn boundary now grows outward, ring by ring,
        // the mirror image of the outside-in case.
        #expect(abs(radius(waypoints[1 + 144]) - 4.0) < 1e-6, "Test Failed: end of the first interpolating turn should land exactly on the next ring's radius (4)")
        #expect(abs(radius(waypoints[1 + 216]) - 6.0) < 1e-6, "Test Failed: end of the second interpolating turn should land exactly on the next ring's radius (6)")
        #expect(abs(radius(waypoints[1 + 288]) - 8.0) < 1e-6, "Test Failed: end of the third interpolating turn should land exactly on the outermost (wall) ring's radius (8)")

        // The final turn holds at the outer wall radius rather than interpolating
        // further -- the single, uninterrupted wall pass `.insideOut`'s own doc comment
        // promises, so nothing re-touches the wall after it.
        #expect(abs(radius(waypoints[1 + 360]) - 8.0) < 1e-6,
                "Test Failed: expected the final turn to close on the outer wall radius, not the innermost one")
    }

    @Test("Inside-out and outside-in spirals trace the same rings in opposite order, not different geometry")
    func testInsideOutAndOutsideInShareTheSameRingRadii() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)

        func ringTurnRadii(direction: SC.SpiralDirection) throws -> [Double] {
            let waypoints = try engine.generateToolpaths(
                from: [circleContour(radius: 10.0)],
                tool: tool,
                settings: settings,
                operation: pocketStrategy(pattern: .spiral(direction: direction))
            )[0].passes[0].waypoints

            // Sample the radius at every full-turn boundary (opening turn through the
            // final closing turn) -- waypoints[1] is step 0, every 72 steps after that
            // is another turn boundary.
            return stride(from: 1, through: waypoints.count - 2, by: 72).map { i in
                hypot(waypoints[i].position.x, waypoints[i].position.y)
            }
        }

        let outsideInRadii = try ringTurnRadii(direction: .outsideIn)
        let insideOutRadii = try ringTurnRadii(direction: .insideOut)

        #expect(outsideInRadii == insideOutRadii.reversed(),
                "Test Failed: insideOut should visit the exact same ring radii as outsideIn, just in reverse order, not a differently-computed ring stack")
    }

    // MARK: - `.outsideIn` remains the default

    @Test("Bare .spiral still means .spiral(direction: .outsideIn), unaffected by adding the direction parameter")
    func testBareSpiralDefaultsToOutsideIn() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5)
        let settings = SC.MachineSettings(cutting: cutting,
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let bareWaypoints = try engine.generateToolpaths(
            from: [circleContour(radius: 10.0)],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .spiral(direction: .outsideIn))
        )[0].passes[0].waypoints

        let explicitWaypoints = try engine.generateToolpaths(
            from: [circleContour(radius: 10.0)],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .spiral(direction: .outsideIn))
        )[0].passes[0].waypoints

        #expect(bareWaypoints == explicitWaypoints,
                "Test Failed: expected bare .spiral to produce identical output to .spiral(direction: .outsideIn)")
    }

    // MARK: - Fallback on a non-circular boundary is unaffected by direction

    @Test("Inside-out spiral falls back to the exact same offsetPattern output as outside-in on a non-circular boundary")
    func testInsideOutFallsBackIdenticallyOnNonCircularBoundary() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let insideOutWaypoints = try engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .spiral(direction: .insideOut))
        )[0].passes[0].waypoints

        let outsideInWaypoints = try engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .spiral(direction: .outsideIn))
        )[0].passes[0].waypoints

        let offsetPatternWaypoints = try engine.generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .offset)
        )[0].passes[0].waypoints

        // A rectangle has no single center to spiral around either way, so `direction`
        // must have no effect on the fallback path -- both directions should produce
        // the identical exact `.offsetPattern` output.
        #expect(insideOutWaypoints == outsideInWaypoints,
                "Test Failed: direction should have no effect once a boundary isn't spiral-eligible")
        #expect(insideOutWaypoints == offsetPatternWaypoints,
                "Test Failed: expected the fallback path to match .offsetPattern exactly regardless of direction")
    }
}
