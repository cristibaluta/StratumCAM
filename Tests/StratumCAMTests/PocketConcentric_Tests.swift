//
//  PocketConcentric_Tests.swift
//  StratumCAM
//

import Testing
import CoreGraphics
import simd
@testable import StratumCAM

struct PocketConcentric_Tests {

    private func rectangleContour(width: Double, height: Double) -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(width, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(width, 0), b: SIMD2<Double>(width, height)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(width, height), b: SIMD2<Double>(0, height)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, height), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true)
    }

    private func waypoints(width: Double, height: Double, direction: SC.SpiralDirection) throws -> [SC.Waypoint] {
        let tool = SC.ToolParams(diameter: 4.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)
        return try SCEngine().generateToolpaths(
            from: [rectangleContour(width: width, height: height)],
            tool: tool,
            settings: settings,
            operation: .pocket(direction: .climb, pattern: .concentric(direction: direction), entry: .plunge)
        )[0].passes[0].waypoints
    }

    private func isArc(_ w: SC.Waypoint) -> Bool {
        switch w.motion {
            case .arcCCW, .arcCW: return true
            default: return false
        }
    }

    @Test("On a square the innermost pass is a perfect circle")
    func testSquareStartsAsCircle() throws {
        let w = try waypoints(width: 24, height: 24, direction: .insideOut)
        // Wall ring is [2,22]^2, centre (12,12); innermost circle radius = stepover = 2.
        for i in 1...4 {
            let p = w[i].position
            #expect(abs(hypot(Double(p.x) - 12, Double(p.y) - 12) - 2.0) < 1e-6,
                    "Test Failed: waypoint \(i) should lie on the central circle")
        }
        #expect(isArc(w[2]) && isArc(w[3]) && isArc(w[4]) && isArc(w[5]), "Test Failed: first pass should be arcs")
    }

    @Test("On a rectangle the passes start as arcs at the centre and finish on the sharp wall rectangle")
    func testRectangleMorphsToWallRectangle() throws {
        let w = try waypoints(width: 40, height: 24, direction: .insideOut)

        // Starts as a perfect circle at the centre (12 mm tall half-height 10, stepover 2 -> radius 2).
        for i in 1...4 {
            let p = w[i].position
            #expect(abs(hypot(Double(p.x) - 20, Double(p.y) - 12) - 2.0) < 1e-6,
                    "Test Failed: waypoint \(i) should lie on the central circle")
        }

        for p in w.dropFirst().dropLast().map(\.position) {
            #expect(p.x >= 2 - 1e-6 && p.x <= 38 + 1e-6 && p.y >= 2 - 1e-6 && p.y <= 22 + 1e-6,
                    "Test Failed: \(p) escapes the wall offset")
        }

        // The final pass is the sharp wall rectangle: its four corners are all visited.
        let tail = w.suffix(8).map(\.position)
        for corner in [(2.0, 2.0), (38.0, 2.0), (38.0, 22.0), (2.0, 22.0)] {
            #expect(tail.contains { abs(Double($0.x) - corner.0) < 1e-6 && abs(Double($0.y) - corner.1) < 1e-6 },
                    "Test Failed: wall rectangle corner \(corner) missing from the final pass")
        }
        #expect(!isArc(w[w.count - 2]), "Test Failed: final pass should have straight edges")
    }

    @Test("Outside-in is the same rings in reverse order, ending at the centre")
    func testOutsideInEndsAtCentre() throws {
        let w = try waypoints(width: 24, height: 24, direction: .outsideIn)
        let last = w[w.count - 2].position
        #expect(abs(hypot(Double(last.x) - 12, Double(last.y) - 12) - 2.0) < 1e-6,
                "Test Failed: outside-in should finish on the central circle")
    }
}
