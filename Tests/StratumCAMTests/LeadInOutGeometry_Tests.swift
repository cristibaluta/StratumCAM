//
//  LeadInOutGeometry_Tests.swift
//  StratumCAM
//
//  What a lead-in / lead-out actually does to the path (the panel's drawing promises this):
//  a linear lead runs `length` mm along the line the cut starts / ends on, an arc lead has
//  the given radius and sweep and its centre on the free side of the wall (outside the part
//  for an outside cut, inside the shape for an inside cut), and both repeat at every depth.
//

import Testing
import Foundation
@testable import StratumCAM

struct LeadInOutGeometry_Tests {

    private let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 0.5, stepoverPercentage: 0.4),
                                              safeZ: 5,
                                              targetDepth: -1)

    private func rectangle(width: Double, height: Double) -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(width, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(width, 0), b: SIMD2<Double>(width, height)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(width, height), b: SIMD2<Double>(0, height)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, height), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true)
    }

    private func passes(side: SC.CutSide,
                        direction: SC.CutDirection,
                        leadIn: SC.LeadInOut?,
                        leadOut: SC.LeadInOut?,
                        width: Double = 40,
                        height: Double = 30) throws -> [SC.ToolpathPass] {
        let operation: SC.MachiningOperation = .contour(side: side,
                                                        direction: direction,
                                                        entry: .plunge,
                                                        leadIn: leadIn,
                                                        leadOut: leadOut,
                                                        tabs: [])
        let paths = try SCEngine().generateToolpaths(from: [rectangle(width: width, height: height)],
                                                     tool: SC.ToolParams(diameter: 3),
                                                     settings: settings,
                                                     operation: operation)
        return try #require(paths.first).passes
    }

    private func isInsidePart(_ x: Double, _ y: Double, width: Double, height: Double) -> Bool {
        x > 0 && x < width && y > 0 && y < height
    }

    /// Angle from `center` to `point`.
    private func angle(from center: CGPoint, to point: SIMD3<Double>) -> Double {
        atan2(point.y - center.y, point.x - center.x)
    }

    /// The arc centre of a waypoint's motion, whichever way it turns.
    private func arcCenter(of motion: SC.MotionType) -> CGPoint? {
        switch motion {
            case .arcCW(let center), .arcCCW(let center):
                return center
            default:
                return nil
        }
    }

    // MARK: Linear

    @Test("A linear lead-in plunges `length` mm before the contour and arrives on it at the lead feed")
    func testLinearLeadIn() throws {
        let lead = SC.LeadInOut(style: .linear(length: 4), feedRate: 250)
        for side in [SC.CutSide.outside, .inside] {
            for pass in try passes(side: side, direction: .climb, leadIn: lead, leadOut: nil) {
                let plunge = pass.waypoints[1]
                let move = pass.waypoints[2]

                #expect(plunge.position.z == pass.depthZ)
                #expect(plunge.feedRate == settings.cutting.plungeRate)
                #expect(move.motion == .linear)
                #expect(move.feedRate == 250)
                #expect(move.position.z == pass.depthZ)

                let run = hypot(move.position.x - plunge.position.x, move.position.y - plunge.position.y)
                #expect(abs(run - 4) < 1e-9)
            }
        }
    }

    // MARK: Arc

    @Test("An arc lead-in has the requested radius and sweep, ends on the contour, and swings out to the free side")
    func testArcLeadInGeometry() throws {
        let radius = 3.0
        let sweep = 90.0
        let lead = SC.LeadInOut(style: .arc(radius: radius, sweepAngleDegrees: sweep), feedRate: 250)
        let width = 40.0, height = 30.0

        for side in [SC.CutSide.outside, .inside] {
            for direction in [SC.CutDirection.climb, .conventional] {
                for pass in try passes(side: side, direction: direction, leadIn: lead, leadOut: nil, width: width, height: height) {
                    let entry = pass.waypoints[1].position
                    let move = pass.waypoints[2]
                    let center = try #require(arcCenter(of: move.motion))

                    #expect(move.feedRate == 250)
                    #expect(move.position.z == pass.depthZ)

                    // Both ends are on the circle of the requested radius...
                    #expect(abs(hypot(entry.x - center.x, entry.y - center.y) - radius) < 1e-9)
                    #expect(abs(hypot(move.position.x - center.x, move.position.y - center.y) - radius) < 1e-9)

                    // ...and are `sweep` degrees apart.
                    var delta = abs(angle(from: center, to: move.position) - angle(from: center, to: entry))
                    if delta > .pi { delta = 2 * .pi - delta }
                    #expect(abs(delta * 180 / .pi - sweep) < 1e-6)

                    // The centre is on the free side: outside the part, or inside the shape.
                    let centerIsInsideShape = isInsidePart(center.x, center.y, width: width, height: height)
                    #expect(centerIsInsideShape == (side == .inside))
                }
            }
        }
    }

    @Test("An arc lead-out has the requested radius and sweep, starts on the contour end, and swings out to the free side")
    func testArcLeadOutGeometry() throws {
        let radius = 3.0
        let sweep = 90.0
        let lead = SC.LeadInOut(style: .arc(radius: radius, sweepAngleDegrees: sweep), feedRate: 250)
        let width = 40.0, height = 30.0

        for side in [SC.CutSide.outside, .inside] {
            for pass in try passes(side: side, direction: .climb, leadIn: nil, leadOut: lead, width: width, height: height) {
                let exit = pass.waypoints[pass.waypoints.count - 2]
                let retract = pass.waypoints[pass.waypoints.count - 1]
                let contourEnd = pass.waypoints[pass.waypoints.count - 3].position
                let center = try #require(arcCenter(of: exit.motion))

                #expect(exit.feedRate == 250)
                #expect(exit.position.z == pass.depthZ)
                #expect(abs(hypot(contourEnd.x - center.x, contourEnd.y - center.y) - radius) < 1e-9)
                #expect(abs(hypot(exit.position.x - center.x, exit.position.y - center.y) - radius) < 1e-9)

                var delta = abs(angle(from: center, to: exit.position) - angle(from: center, to: contourEnd))
                if delta > .pi { delta = 2 * .pi - delta }
                #expect(abs(delta * 180 / .pi - sweep) < 1e-6)

                let centerIsInsideShape = isInsidePart(center.x, center.y, width: width, height: height)
                #expect(centerIsInsideShape == (side == .inside))

                // The retract rises straight up from where the lead-out ends.
                #expect(retract.motion == .rapid)
                #expect(retract.position.x == exit.position.x)
                #expect(retract.position.y == exit.position.y)
                #expect(retract.position.z == settings.safeZ)
            }
        }
    }

    @Test("An arc lead on a contour the tool follows directly still has a centre, on the outside")
    func testArcLeadsOnContour() throws {
        let radius = 3.0
        let lead = SC.LeadInOut(style: .arc(radius: radius, sweepAngleDegrees: 90), feedRate: 250)
        let width = 40.0, height = 30.0

        for pass in try passes(side: .onContour, direction: .climb, leadIn: lead, leadOut: lead, width: width, height: height) {
            let entry = pass.waypoints[1].position
            let leadIn = pass.waypoints[2]
            let center = try #require(arcCenter(of: leadIn.motion))
            #expect(abs(hypot(entry.x - center.x, entry.y - center.y) - radius) < 1e-9)
            #expect(abs(hypot(leadIn.position.x - center.x, leadIn.position.y - center.y) - radius) < 1e-9)
            #expect(!isInsidePart(center.x, center.y, width: width, height: height))

            let exit = pass.waypoints[pass.waypoints.count - 2]
            let outCenter = try #require(arcCenter(of: exit.motion))
            #expect(abs(hypot(exit.position.x - outCenter.x, exit.position.y - outCenter.y) - radius) < 1e-9)
            #expect(!isInsidePart(outCenter.x, outCenter.y, width: width, height: height))
        }
    }

    @Test("Lead-in and lead-out repeat at every depth pass")
    func testLeadsRepeatEveryPass() throws {
        let lead = SC.LeadInOut(style: .linear(length: 2), feedRate: 250)
        let result = try passes(side: .outside, direction: .climb, leadIn: lead, leadOut: lead)
        #expect(result.count > 1)
        for pass in result {
            #expect(pass.waypoints[2].feedRate == 250)
            #expect(pass.waypoints[pass.waypoints.count - 2].feedRate == 250)
        }
    }
}
