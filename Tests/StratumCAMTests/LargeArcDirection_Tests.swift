//
//  LargeArcDirection_Tests.swift
//  StratumCAM
//
//  `.contour` re-orients the chain to match side + direction (assuming a CW spindle), so the
//  direction the shape was drawn in doesn't decide the cut direction. Backs the two
//  "Large Arc 300°" demos.
//

import Testing
import Foundation
@testable import StratumCAM

struct LargeArcDirection_Tests {

    private let deg = Double.pi / 180

    private func pacMan(reversed: Bool) -> SC.Contour {
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

    /// Motion of the long (300°-ish) arc in the last pass: `true` = CCW (G03), `false` = CW (G02).
    private func bigArcIsCCW(side: SC.CutSide, direction: SC.CutDirection, reversed: Bool) throws -> Bool {
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 0.5, stepoverPercentage: 0.4),
                                          safeZ: 5,
                                          targetDepth: -1)
        let operation: SC.MachiningOperation = .contour(side: side,
                                                        direction: direction,
                                                        entry: .plunge,
                                                        leadIn: nil,
                                                        leadOut: nil,
                                                        tabs: [])
        let paths = try SCEngine().generateToolpaths(from: [pacMan(reversed: reversed)],
                                                     tool: SC.ToolParams(diameter: 3.175),
                                                     settings: settings,
                                                     operation: operation)
        let pass = try #require(paths.first?.passes.last)
        // Skip the small corner-bridge arcs the offset adds around the wedge vertex (radius =
        // tool radius); the big arc has radius ~ 10 -/+ the tool radius.
        for waypoint in pass.waypoints {
            let center: CGPoint
            let isCCW: Bool
            switch waypoint.motion {
                case .arcCCW(let c): center = c; isCCW = true
                case .arcCW(let c): center = c; isCCW = false
                default: continue
            }
            let radius = hypot(Double(waypoint.position.x) - Double(center.x), Double(waypoint.position.y) - Double(center.y))
            if radius > 5 {
                return isCCW
            }
        }
        Issue.record("no big arc found in the toolpath")
        return false
    }

    @Test("Outside climb is CW, whichever way the shape was drawn")
    func testOutsideClimb() throws {
        #expect(try bigArcIsCCW(side: .outside, direction: .conventional, reversed: false))
        #expect(try bigArcIsCCW(side: .outside, direction: .conventional, reversed: true))
    }

    @Test("Inside climb is CCW, whichever way the shape was drawn")
    func testInsideClimb() throws {
        #expect(try !bigArcIsCCW(side: .inside, direction: .conventional, reversed: false))
        #expect(try !bigArcIsCCW(side: .inside, direction: .conventional, reversed: true))
    }

    @Test("Inside conventional is CW")
    func testInsideConventional() throws {
        #expect(try bigArcIsCCW(side: .inside, direction: .climb, reversed: true))
    }
}
