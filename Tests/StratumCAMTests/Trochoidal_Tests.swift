//
//  Trochoidal.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

// Step 1B.2: `.trochoidal` pocketing. Advances along the same oriented boundary chain
// `.offsetPattern`/`.spiral` build via `orientedForDirection`, looping the cutter in
// small overlapping circles sized off `tool.diameter` and
// `settings.cutting.stepoverPercentage` -- same inputs `.raster`/`pocketRings` already
// read, rather than a third trochoidal-only parameter.

struct Trochoidal_Tests {

    // MARK: - Fixtures

    /// A 20x10 CCW rectangle -- same fixture `Pocket_Tests.swift`/`Raster_Tests.swift`
    /// already use.
    private func ccwRectangleContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 0), b: DXF.Point(20, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 10), b: DXF.Point(0, 10), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, 10), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    private func pocketStrategy(entry: SC.EntryStrategy = .plunge, direction: SC.CutDirection = .climb) -> SC.MachiningOperation {
        let settings = SC.TrochoidalSettings(radialEngagement: 4, loopRadius: 0.5)
        return .pocket(direction: direction, pattern: .trochoidal(settings: settings), entry: entry)
    }

    // MARK: - Geometry: loop diameter + advance honored

    @Test("Trochoidal loops trace tool-diameter circles spaced by stepover along a straight boundary")
    func testTrochoidalLoopsHonorDiameterAndStepover() {
        let engine = SCEngine()

        // A single 20mm straight run -- simplest possible boundary to check loop
        // spacing/diameter against by hand, independent of `orientedForDirection`'s
        // own winding logic (covered separately below via the full pocket pipeline).
        let boundary: [SC.Segment] = [.line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 20, y: 0))]

        // 4mm tool (2mm loop radius), 50% stepover -> 2mm advance per loop.
        // 20mm / 2mm = 10 exactly -> 11 loop centers (0, 2, 4, ..., 20), same
        // fencepost convention `rasterScanlines` uses for its own last row.
        let tool = SC.ToolParams(diameter: 4.0)
        let segments = engine.trochoidalSegments(from: boundary, tool: tool, stepoverPercentage: 0.5)

        #expect(!segments.isEmpty, "Test Failed: expected non-empty trochoidal geometry")

        let stepsPerLoop = 72
        let loopCount = 11
        // Each loop is `stepsPerLoop` chords; every loop after the first is preceded
        // by one connecting move from the previous loop's own closing point.
        #expect(segments.count == loopCount * stepsPerLoop + (loopCount - 1),
                "Test Failed: expected \(loopCount) loops of \(stepsPerLoop) chords each plus \(loopCount - 1) connectors, got \(segments.count)")

        // The very first chord starts at the first loop's own start point: 2mm (the
        // loop radius) to the right of the boundary's own start point (0,0).
        let firstChord = segments[0]
        #expect(abs(firstChord.startPoint.x - 2.0) < 1e-6 && abs(firstChord.startPoint.y - 0.0) < 1e-6,
                "Test Failed: expected the first loop to start at (2, 0), got \(firstChord.startPoint)")

        // Every point of the first loop should sit exactly `loopRadius` (2mm) from
        // that loop's own center (0,0) -- i.e. the loop traces a true circle of
        // diameter `tool.diameter`, not some other shape.
        let firstLoopChords = segments[0..<stepsPerLoop]
        for chord in firstLoopChords {
            let distance = hypot(chord.endPoint.x - 0.0, chord.endPoint.y - 0.0)
            #expect(abs(distance - 2.0) < 1e-6,
                    "Test Failed: expected every point on the first loop to be 2mm (tool radius) from its center, got \(distance)")
        }

        // The last loop is pinned exactly at the boundary's own end point (20, 0),
        // same fencepost convention `rasterScanlines`/`calculateZPasses` use for
        // their own last row/depth, rather than landing short of, or past, the
        // boundary's true end.
        let lastLoopChords = segments.suffix(stepsPerLoop)
        for chord in lastLoopChords {
            let distance = hypot(chord.endPoint.x - 20.0, chord.endPoint.y - 0.0)
            #expect(abs(distance - 2.0) < 1e-6,
                    "Test Failed: expected every point on the last loop to be 2mm from its center at (20, 0), got \(distance)")
        }

        // Consecutive loop centers are exactly `stepoverPercentage * tool.diameter`
        // (2mm) apart -- proof the requested overlap, not some other spacing, is
        // what's actually driving the loop-to-loop advance.
        let connector = segments[stepsPerLoop] // the connector right after loop 0.
        let firstLoopEnd = firstLoopChords.last!.endPoint
        #expect(abs(connector.startPoint.x - firstLoopEnd.x) < 1e-6 && abs(connector.startPoint.y - firstLoopEnd.y) < 1e-6,
                "Test Failed: expected the connector to start exactly where the previous loop closed")
        #expect(abs(connector.endPoint.x - 4.0) < 1e-6 && abs(connector.endPoint.y - 0.0) < 1e-6,
                "Test Failed: expected the second loop to start at (4, 0), 2mm further along than the first")

        // Since the advance (2mm) is smaller than the loop diameter (4mm), every
        // pair of consecutive loop centers is closer together than the loop
        // diameter -- the defining property of "overlapping" trochoidal loops,
        // rather than a chain of loops that never touch.
        #expect(2.0 < tool.diameter, "Test Failed: fixture should exercise genuinely overlapping loops")
    }

    @Test("Trochoidal advance/diameter scale with a different tool and stepover")
    func testTrochoidalHonorsDifferentToolAndStepover() {
        let engine = SCEngine()
        let boundary: [SC.Segment] = [.line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 30, y: 0))]

        // 6mm tool (3mm loop radius), 331/3% stepover -> 2mm advance. 30mm / 2mm = 15
        // exactly -> 16 loop centers.
        let tool = SC.ToolParams(diameter: 6.0)
        let segments = engine.trochoidalSegments(from: boundary, tool: tool, stepoverPercentage: 2.0 / 6.0)

        let stepsPerLoop = 72
        let loopCount = 16
        #expect(segments.count == loopCount * stepsPerLoop + (loopCount - 1),
                "Test Failed: expected \(loopCount) loops, got a geometry consistent with \((segments.count - (loopCount - 1)) / stepsPerLoop)")

        let firstLoopEnd = segments[stepsPerLoop - 1].endPoint
        #expect(abs(firstLoopEnd.x - 3.0) < 1e-6 && abs(firstLoopEnd.y - 0.0) < 1e-6,
                "Test Failed: expected the first loop (radius 3mm, centered at the boundary start) to close back on its own start point (3, 0)")

        let secondLoopStart = segments[stepsPerLoop].endPoint
        #expect(abs(secondLoopStart.x - 5.0) < 1e-6 && abs(secondLoopStart.y - 0.0) < 1e-6,
                "Test Failed: expected the second loop (centered 2mm along the boundary, radius 3mm) to start at (5, 0)")
    }

    // MARK: - Full pocket pipeline

    @Test("Trochoidal pocket wires into the same rapid/plunge/retract wrapper as the other patterns")
    func testTrochoidalPocketWiresIntoPocketWrapper() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0)
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
            operation: pocketStrategy()
        )

        #expect(toolpaths.count == 1, "Test Failed: expected 1 pocket toolpath")

        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 1, "Test Failed: expected exactly one Z pass")

        let waypoints = toolpath.passes[0].waypoints

        // rapid + plunge + one waypoint per traced chord (loops + connectors) + retract.
        // 20x10 rectangle perimeter is 60mm; 2mm advance -> 31 loop centers (0...60
        // inclusive every 2mm) and 30 connectors, 72 chords/loop.
        let stepsPerLoop = 72
        let loopCount = 31
        let expectedTraceCount = loopCount * stepsPerLoop + (loopCount - 1)
        #expect(waypoints.count == expectedTraceCount + 3,
                "Test Failed: expected rapid + plunge + \(expectedTraceCount) traced moves + retract, got \(waypoints.count)")

        #expect(waypoints[0].position.z == 5.0, "Test Failed: expected the initial rapid at safeZ")
        if case .rapid = waypoints[0].motion {} else {
            Issue.record("Test Failed: first waypoint motion must be .rapid")
        }

        #expect(waypoints[1].position.z == -1.0, "Test Failed: expected a single plunge to targetDepth")

        #expect(waypoints.last?.position.z == 5.0, "Test Failed: expected the final retract to safeZ")
        if case .rapid = waypoints.last?.motion {} else {
            Issue.record("Test Failed: last waypoint motion must be .rapid")
        }

        // Every traced move stays within a loop radius of the pocket's own outer
        // bounds -- the loops are centered directly on the boundary, so nothing
        // should stray far outside the original 20x10 rectangle.
        let xs = waypoints.map { $0.position.x }
        let ys = waypoints.map { $0.position.y }
        #expect((xs.min() ?? 0) > -2.01 && (xs.max() ?? 0) < 22.01,
                "Test Failed: trochoidal loops strayed further than a loop radius outside the pocket's X bounds")
        #expect((ys.min() ?? 0) > -2.01 && (ys.max() ?? 0) < 12.01,
                "Test Failed: trochoidal loops strayed further than a loop radius outside the pocket's Y bounds")
    }

    @Test("Trochoidal pocket's geometry is reused unchanged across Z passes, same as offsetPattern/spiral")
    func testTrochoidalPocketGeometryReusedAcrossZPasses() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0)
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
            operation: pocketStrategy()
        )

        let passes = toolpaths[0].passes
        #expect(passes.count == 2, "Test Failed: expected 2 Z passes for a -2.0 depth at 1.0 stepdown")

        let firstPassWaypoints = passes[0].waypoints
        let secondPassWaypoints = passes[1].waypoints
        #expect(firstPassWaypoints.count == secondPassWaypoints.count,
                "Test Failed: the trochoidal geometry should be identical in shape across passes")

        for i in 0..<firstPassWaypoints.count {
            let a = firstPassWaypoints[i].position
            let b = secondPassWaypoints[i].position
            #expect(abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9,
                    "Test Failed: waypoint \(i)'s XY differs between passes -- trochoidal geometry should be computed once and reused")
        }
    }

    // MARK: - Validation

    @Test("An open contour does not produce a trochoidal pocket toolpath")
    func testTrochoidalPocketRequiresClosedContour() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                    plungeRate: 300.0,
                                                                    stepdown: 1.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let openContour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(10, 0), b: DXF.Point(10, 10), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = engine.generateToolpaths(
            from: [openContour],
            tool: tool,
            settings: settings,
            operation: pocketStrategy()
        )

        #expect(toolpaths.isEmpty, "Test Failed: open contours must not generate trochoidal pocket toolpaths")
    }
}
