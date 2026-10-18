//
//  ArcSweep_Tests.swift
//  StratumCAM
//
//  Arcs built from `atan2` (bulge polylines, trimmed corners) store angles in (-π, π], so a
//  CCW arc crossing the ±π seam has `endAngle < startAngle`. Lengths, interpolation and
//  winding must still follow the direction of travel, not the raw angle difference.
//

import Testing
import Foundation
@testable import StratumCAM

struct ArcSweep_Tests {

    private let deg = Double.pi / 180

    @Test("sweepAngle follows the direction of travel across the ±π seam")
    func testSweepAngle() {
        // CCW 170° -> -170° crosses the seam: 20°
        #expect(abs(SC.Segment.sweepAngle(start: 170 * deg, end: -170 * deg, isCCW: true) - 20 * deg) < 1e-9)
        // CW -170° -> 170° crosses the seam the other way: 20°
        #expect(abs(SC.Segment.sweepAngle(start: -170 * deg, end: 170 * deg, isCCW: false) - 20 * deg) < 1e-9)
        // Ordered angles are unchanged
        #expect(abs(SC.Segment.sweepAngle(start: 0, end: 90 * deg, isCCW: true) - 90 * deg) < 1e-9)
        #expect(abs(SC.Segment.sweepAngle(start: 90 * deg, end: 0, isCCW: false) - 90 * deg) < 1e-9)
        // Going the long way round is the complement
        #expect(abs(SC.Segment.sweepAngle(start: 170 * deg, end: -170 * deg, isCCW: false) - 340 * deg) < 1e-9)
        // Full turn and empty arc
        #expect(abs(SC.Segment.sweepAngle(start: 0, end: 2 * .pi, isCCW: true) - 2 * .pi) < 1e-9)
        #expect(SC.Segment.sweepAngle(start: 1, end: 1, isCCW: true) == 0)
    }

    @Test("pathLength of an arc crossing ±π is its real length, CCW and CW")
    func testPathLengthAcrossSeam() {
        let expected = 10.0 * 20 * deg
        let ccw = SC.Segment.arc(center: .zero, radius: 10, startAngle: 170 * deg, endAngle: -170 * deg, isCCW: true)
        let cw = SC.Segment.arc(center: .zero, radius: 10, startAngle: -170 * deg, endAngle: 170 * deg, isCCW: false)

        #expect(abs(ccw.pathLength - expected) < 1e-9)
        #expect(abs(cw.pathLength - expected) < 1e-9)
    }

    @Test("A bulge arc crossing ±π has the geometric arc length")
    func testBulgeArcLength() {
        // (-10, 1) -> (-10, -1), bulge > 0: CCW arc around its center on the right,
        // passing through angle π -- exactly the seam.
        let bulge = 0.2
        let contour = SC.Contour(
            entities: [.init(geometry: .polyline(vertices: [.init(SIMD2(-10, 1), bulge: bulge),
                                                          .init(SIMD2(-10, -1))],
                                               closed: false),
                             reversed: false)],
            isClosed: false
        )

        let segments = contour.linearizedSegments
        #expect(segments.count == 1)

        let theta = 4 * atan(bulge)
        let radius = 1.0 / sin(theta / 2)
        #expect(abs(segments[0].pathLength - radius * theta) < 1e-9)
    }

    @Test("Winding of a closed shape with a seam-crossing bulge arc is detected correctly")
    func testWindingWithSeamArc() {
        // Down the arc on the left, back up the straight side on the right: CCW.
        let contour = SC.Contour(
            entities: [.init(geometry: .polyline(vertices: [.init(SIMD2(-10, 1), bulge: 0.2),
                                                          .init(SIMD2(-10, -1))],
                                               closed: true),
                             reversed: false)],
            isClosed: true
        )

        #expect(OffsetTools.isCCWWinding(contour.linearizedSegments))
    }

    /// The "Large Arc 300°" demo shape: a Pac-Man, i.e. a 300° bulge arc (crossing the ±π seam)
    /// closed by a wedge back to the center.
    private func pacMan(reversed: Bool = false) -> SC.Contour {
        let mouth = 30 * deg
        let radius = 10.0
        let shape = SC.Geometry.polyline(
            vertices: [.init(SIMD2(radius * cos(mouth), radius * sin(mouth)), bulge: tan(300 * deg / 4)),
                       .init(SIMD2(radius * cos(-mouth), radius * sin(-mouth))),
                       .init(SIMD2(0, 0))],
            closed: true
        )
        return SC.Contour(entities: [.init(geometry: shape, reversed: reversed)], isClosed: true)
    }

    @Test("Large-arc demo shape: the 300° arc is measured as 300°, forward and reversed")
    func testPacManLength() {
        let expected = 10.0 * 300 * deg + 10.0 + 10.0

        #expect(abs(pacMan().linearizedSegments.pathLength - expected) < 1e-6)
        #expect(abs(pacMan(reversed: true).linearizedSegments.pathLength - expected) < 1e-6)
        #expect(OffsetTools.isCCWWinding(pacMan().linearizedSegments))
        #expect(!OffsetTools.isCCWWinding(pacMan(reversed: true).linearizedSegments))
    }

    @Test("Large-arc demo shape: tabs on the 300° arc clamp Z to the tab floor")
    func testPacManTabs() throws {
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 0.5),
                                          safeZ: 5,
                                          targetDepth: -3)
        let operation: SC.MachiningOperation = .contour(
            side: .outside,
            direction: .climb,
            entry: .plunge,
            leadIn: nil,
            leadOut: nil,
            tabs: [SC.HoldingTab(positionRatio: 0.35, width: 6, height: 1.5)]
        )

        let paths = try SCEngine().generateToolpaths(from: [pacMan()],
                                                     tool: SC.ToolParams(diameter: 3.175),
                                                     settings: settings,
                                                     operation: operation)
        let lastPass = try #require(paths.first?.passes.last)
        let tabFloor = -1.5
        let cutting = lastPass.waypoints.filter { $0.motion != .rapid && $0.position.z < 0 }

        // Part of the last pass is held at the tab floor, the rest reaches full depth.
        #expect(cutting.contains { abs($0.position.z - tabFloor) < 1e-9 })
        #expect(cutting.contains { abs($0.position.z - (-3)) < 1e-9 })
    }
}
