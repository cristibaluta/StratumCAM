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

struct Trochoidal_Tests {

    // MARK: - Fixtures

    /// A 20x10 CCW rectangle
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
/*
    @Test("Trochoidal loops trace tool-diameter circles spaced by stepover along a straight boundary")
    func testTrochoidalLoopsHonorDiameterAndStepover() {
        let engine = SCEngine()
        let boundary: [SC.Segment] = [.line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 20, y: 0))]

        // 4mm tool (2mm loop radius), 50% stepover -> 2mm advance per loop.
        // 20mm / 2mm = 10 exactly -> 11 loop centers (0, 2, 4, ..., 20), same
        // fencepost convention `rasterScanlines` uses for its own last row.
        let tool = SC.ToolParams(diameter: 4.0)
        let segments = engine.trochoidalSegments(from: boundary, tool: tool, radialEngagement: 50, loopRadius: 0.5)

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
    }*/
}
