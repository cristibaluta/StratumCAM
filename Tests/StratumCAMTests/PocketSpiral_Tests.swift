//
//  PocketSpiral.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 12.09.2026.
//

import Testing
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
            .init(geometry: .circle(center: SIMD2<Double>(0, 0), radius: radius), reversed: false)
        ], isClosed: true)
    }

    /// A 20x10 CCW rectangle -- same fixture `Pocket_Tests.swift`/`PocketZPasses_Tests.swift`
    /// already use. Not circular, so `.spiral` must fall back on it.
    private func ccwRectangleContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(20, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(20, 0), b: SIMD2<Double>(20, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(20, 10), b: SIMD2<Double>(0, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, 10), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true)
    }

    private func pocketStrategy(pattern: SC.PocketClearingPattern, entry: SC.EntryStrategy = .plunge, direction: SC.CutDirection = .climb) -> SC.MachiningOperation {
        .pocket(direction: direction, pattern: pattern, entry: entry)
    }

    // MARK: - Continuous spiral on a circular boundary

    @Test("Spiral pocket interpolates continuously inward on a circular boundary, not in discrete ring jumps")
    func testSpiralPocketTracesContinuousInwardSpiralOnCircularBoundary() throws {
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

        let toolpaths = try engine.generateToolpaths(
            from: [circleContour(radius: 10.0)],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .spiral(direction: .outsideIn))
        )

        #expect(toolpaths.count == 1, "Test Failed: expected 1 pocket toolpath")
        let waypoints = toolpaths[0].passes[0].waypoints

        // rapid + plunge + (4 rings + 1 bookend turn, x 72 steps/turn) + retract. The
        // spiral has one interpolating turn per ring-to-ring transition (3, for 4 rings)
        // plus two constant-radius bookend turns: one holding the outermost (wall) ring's
        // radius so that ring is actually swept all the way round before the path starts
        // moving inward, and one holding the innermost ring's radius to close the pocket
        // floor. 72 steps/turn is an internal tessellation choice (5 degrees/step) -- if
        // that constant ever changes, this count is expected to move with it.
        #expect(waypoints.count == 2 + 5 * 72 + 1,
                "Test Failed: expected 363 waypoints (rapid, plunge, 360 spiral steps, retract), got \(waypoints.count)")

        func radius(_ waypoint: SC.Waypoint) -> Double {
            hypot(waypoint.position.x, waypoint.position.y)
        }

        // The plunge lands on the outermost ring's own start point (radius 8) --
        // same entry convention `.offsetPattern` uses.
        #expect(waypoints[0].position.z == 5.0, "Test Failed: expected the initial rapid at safeZ")
        #expect(radius(waypoints[1]) ~= 8.0, "Test Failed: plunge should land on the outermost ring's radius")
        #expect(waypoints[1].position.z == -1.0, "Test Failed: plunge should land at target depth")

        // The opening turn (steps 0-71, i.e. waypoints[1]...[73]) must hold at the
        // outermost ring's own radius (8) all the way round -- not just at the start
        // angle. This is the regression guard for the bug where an interpolating first
        // turn only ever touched the true wall-offset radius once, at the start angle,
        // then immediately drifted inward, leaving up to a full stepover's width of the
        // outermost band never swept.
        #expect(radius(waypoints[1 + 18]) ~= 8.0, "Test Failed: quarter-way round the opening turn should still be at the outermost radius")
        #expect(radius(waypoints[1 + 54]) ~= 8.0, "Test Failed: three-quarters round the opening turn should still be at the outermost radius")
        #expect(radius(waypoints[1 + 72]) ~= 8.0, "Test Failed: the opening turn should close back on itself at the outermost radius")

        // Radius at each subsequent full-turn boundary matches that ring's own radius
        // exactly -- proof the spiral is genuinely passing through the same rings
        // `pocketRings` computed, not some independently-derived curve.
        #expect(radius(waypoints[1 + 144]) ~= 6.0, "Test Failed: end of the first interpolating turn should land exactly on ring 1's radius (6)")
        #expect(radius(waypoints[1 + 216]) ~= 4.0, "Test Failed: end of the second interpolating turn should land exactly on ring 2's radius (4)")
        #expect(radius(waypoints[1 + 288]) ~= 2.0, "Test Failed: end of the third interpolating turn should land exactly on ring 3's (innermost) radius (2)")

        // Midway through the first interpolating turn (steps 72-144), the radius should
        // sit halfway between ring 0 and ring 1 (8 -> 6, so 7) -- proof of genuine
        // continuous interpolation mid-turn, not a discrete jump that only happens to
        // land correctly at the turn boundaries checked above.
        #expect(radius(waypoints[1 + 108]) ~= 7.0,
                "Test Failed: expected the midpoint of the first interpolating turn to be halfway between ring 0 and ring 1's radius")

        // The final turn is the "closes on itself" pass the `.spiral` case's own doc
        // comment describes -- it holds at the innermost radius rather than
        // interpolating toward anything further.
        #expect(radius(waypoints[1 + 360]) ~= 2.0,
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
    func testSpiralPocketGeometryReusedAcrossZPasses() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                    plungeRate: 300.0,
                                                                    stepdown: 1.0,
                                                                    stepoverPercentage: 0.5),
                                          safeZ: 5.0,
                                          targetDepth: -2.0)

        let toolpaths = try engine.generateToolpaths(
            from: [circleContour(radius: 10.0)],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .spiral(direction: .outsideIn))
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
            #expect(a.x ~= b.x && a.y ~= b.y,
                    "Test Failed: waypoint \(i)'s XY differs between passes -- spiral geometry should be computed once and reused")
        }
    }

    // MARK: - Continuous spiral on an axis-aligned rectangle

    private func rectangleSpiralWaypoints(direction: SC.SpiralDirection,
                                          cut: SC.CutDirection = .climb,
                                          toolDiameter: Double = 6.0) throws -> [SC.Waypoint] {
        let tool = SC.ToolParams(diameter: toolDiameter)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)
        return try SCEngine().generateToolpaths(
            from: [ccwRectangleContour()],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .spiral(direction: direction), direction: cut)
        )[0].passes[0].waypoints
    }

    @Test("Inside-out spiral on a rectangle starts at the centre and is one unbroken cut")
    func testRectangleSpiralStartsAtCentreAndNeverLiftsOrJumps() throws {
        // 20x10 pocket, 6mm tool -> tool-centre region is [3,17] x [3,7], centre (10,5).
        let waypoints = try rectangleSpiralWaypoints(direction: .insideOut)
        let plunge = waypoints[1].position

        // Entry is on the small centre circle (radius 95% of the tool radius, capped by the
        // half-height 2), directly below the centre -- not on the wall ring.
        #expect(abs(plunge.x - 10.0) < 1e-6, "Test Failed: plunge should be at the middle of the centre ring's bottom")
        #expect(hypot(plunge.x - 10.0, plunge.y - 5.0) <= 2.0 + 1e-6, "Test Failed: inside-out should plunge at the centre, not at the wall")
        #expect(waypoints[1].position.z == -1.0, "Test Failed: plunge should land at target depth")

        // rapid, plunge, ...cutting moves only..., retract: one continuous spiral.
        for i in 2..<(waypoints.count - 1) {
            #expect(waypoints[i].motion != .rapid, "Test Failed: waypoint \(i) is a rapid inside the spiral")
        }
        #expect(waypoints.last?.motion == .rapid && waypoints.last?.position.z == 5.0, "Test Failed: expected a single retract at the end")
    }

    @Test("Rectangle spiral never leaves the tool-centre region and finishes with a full wall pass")
    func testRectangleSpiralStaysInsideAndEndsOnWall() throws {
        let waypoints = try rectangleSpiralWaypoints(direction: .insideOut)

        for i in 1..<(waypoints.count - 1) {
            let p = waypoints[i].position
            #expect(p.x >= 3.0 - 1e-6 && p.x <= 17.0 + 1e-6 && p.y >= 3.0 - 1e-6 && p.y <= 7.0 + 1e-6,
                    "Test Failed: waypoint \(i) at (\(p.x), \(p.y)) leaves the wall offset rectangle")
        }

        // Closing pass: the last cutting waypoints trace the sharp wall rectangle, so all four
        // corners of the tool-centre region are visited, and the spiral ends on its start.
        let cutting = waypoints[1..<(waypoints.count - 1)].map { $0.position }
        for corner in [(3.0, 3.0), (17.0, 3.0), (17.0, 7.0), (3.0, 7.0)] {
            #expect(cutting.contains { abs($0.x - corner.0) < 1e-6 && abs($0.y - corner.1) < 1e-6 },
                    "Test Failed: wall corner \(corner) is never reached")
        }
        let last = cutting[cutting.count - 1]
        #expect(abs(last.x - 10.0) < 1e-6 && abs(last.y - 3.0) < 1e-6, "Test Failed: the wall pass should close at the middle of the bottom wall")
    }

    @Test("Rectangle spiral is not the offset-ring fallback any more, and outside-in reverses the order")
    func testRectangleSpiralIsRealAndDirectionReversesIt() throws {
        let insideOut = try rectangleSpiralWaypoints(direction: .insideOut)
        let outsideIn = try rectangleSpiralWaypoints(direction: .outsideIn)

        let offsetPattern = try SCEngine().generateToolpaths(
            from: [ccwRectangleContour()],
            tool: SC.ToolParams(diameter: 6.0),
            settings: SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4),
                                         safeZ: 5.0,
                                         targetDepth: -1.0),
            operation: pocketStrategy(pattern: .offset)
        )[0].passes[0].waypoints

        #expect(insideOut != offsetPattern, "Test Failed: rectangle spiral still equals the offset fallback")
        #expect(insideOut != outsideIn, "Test Failed: direction should change the rectangle spiral")

        // Outside-in plunges on the wall ring (bottom middle, y = 3) and finishes at the centre.
        let start = outsideIn[1].position
        #expect(abs(start.x - 10.0) < 1e-6 && abs(start.y - 3.0) < 1e-6, "Test Failed: outside-in should plunge on the wall")
        let end = outsideIn[outsideIn.count - 2].position
        #expect(hypot(end.x - 10.0, end.y - 5.0) <= 2.0 + 1e-6, "Test Failed: outside-in should finish at the centre")
    }

    @Test("Rectangle spiral keeps the requested climb/conventional winding")
    func testRectangleSpiralRespectsCutDirection() throws {
        func signedArea(_ waypoints: [SC.Waypoint]) -> Double {
            // Shoelace over the final wall pass (last 5 cutting points of a sharp rectangle ring).
            let pts = waypoints[1..<(waypoints.count - 1)].map { $0.position }.suffix(5)
            var area = 0.0
            let a = Array(pts)
            for i in 0..<(a.count - 1) { area += a[i].x * a[i + 1].y - a[i + 1].x * a[i].y }
            return area
        }
        let climb = signedArea(try rectangleSpiralWaypoints(direction: .insideOut, cut: .climb))
        let conventional = signedArea(try rectangleSpiralWaypoints(direction: .insideOut, cut: .conventional))
        #expect(climb * conventional < 0, "Test Failed: climb and conventional should wind opposite ways")
    }

    // MARK: - Fallback on other non-circular boundaries

    @Test("Spiral pocket falls back on a rounded rectangle too -- only a plain circle is eligible")
    func testSpiralPocketFallsBackOnRoundedRectangle() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        // A 20x10 rectangle with 2mm corner radii: some segments are arcs, but they
        // don't share one common center/radius the way a plain circle's do.
        let roundedRectangleContour = SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(2, 0), b: SIMD2<Double>(18, 0)), reversed: false),
            .init(geometry: .arc(center: SIMD2<Double>(18, 2), radius: 2.0, startDeg: -90, endDeg: 0), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(20, 2), b: SIMD2<Double>(20, 8)), reversed: false),
            .init(geometry: .arc(center: SIMD2<Double>(18, 8), radius: 2.0, startDeg: 0, endDeg: 90), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(18, 10), b: SIMD2<Double>(2, 10)), reversed: false),
            .init(geometry: .arc(center: SIMD2<Double>(2, 8), radius: 2.0, startDeg: 90, endDeg: 180), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, 8), b: SIMD2<Double>(0, 2)), reversed: false),
            .init(geometry: .arc(center: SIMD2<Double>(2, 2), radius: 2.0, startDeg: 180, endDeg: 270), reversed: false)
        ], isClosed: true)

        let spiralWaypoints = try engine.generateToolpaths(
            from: [roundedRectangleContour],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .spiral(direction: .outsideIn))
        )[0].passes[0].waypoints

        let offsetPatternWaypoints = try engine.generateToolpaths(
            from: [roundedRectangleContour],
            tool: tool,
            settings: settings,
            operation: pocketStrategy(pattern: .offset)
        )[0].passes[0].waypoints

        #expect(spiralWaypoints == offsetPatternWaypoints,
                "Test Failed: a rounded rectangle has 4 different arc centers, not 1 -- .spiral should fall back here too")
    }
}
