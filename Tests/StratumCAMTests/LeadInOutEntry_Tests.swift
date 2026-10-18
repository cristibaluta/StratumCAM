//
//  LeadInOutEntry_Tests.swift
//  StratumCAM
//
//  A lead-in is the approach move the tool plunges at, so it can't be combined with a ramp or
//  helix entry (those descend along the contour themselves): that is an error, not a silently
//  dropped lead-in. A lead-out only depends on how the cut ends and works with every entry.
//

import Testing
import Foundation
@testable import StratumCAM

struct LeadInOutEntry_Tests {

    private let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 0.5),
                                              safeZ: 5,
                                              targetDepth: -1)

    private let linearLead = SC.LeadInOut(style: .linear(length: 2), feedRate: 400)

    private func rectangle() -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(20, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(20, 0), b: SIMD2<Double>(20, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(20, 10), b: SIMD2<Double>(0, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, 10), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true)
    }

    private func generate(entry: SC.EntryStrategy, leadIn: SC.LeadInOut?, leadOut: SC.LeadInOut?) throws -> [SC.ToolpathPass] {
        let operation: SC.MachiningOperation = .contour(side: .outside,
                                                        direction: .climb,
                                                        entry: entry,
                                                        leadIn: leadIn,
                                                        leadOut: leadOut,
                                                        tabs: [])
        let paths = try SCEngine().generateToolpaths(from: [rectangle()],
                                                     tool: SC.ToolParams(diameter: 3),
                                                     settings: settings,
                                                     operation: operation)
        return try #require(paths.first).passes
    }

    private func expectInvalidParameter(_ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected SC.Error.invalidParameter to be thrown")
        } catch SC.Error.invalidParameter {
            // expected
        } catch {
            Issue.record("expected SC.Error.invalidParameter, got \(error)")
        }
    }

    @Test("A lead-in with a ramp entry is rejected")
    func testLeadInWithRampThrows() {
        expectInvalidParameter {
            _ = try generate(entry: .ramp(angleDegrees: 3), leadIn: linearLead, leadOut: nil)
        }
    }

    @Test("A lead-in with a helix entry is rejected")
    func testLeadInWithHelixThrows() {
        expectInvalidParameter {
            _ = try generate(entry: .helix(radius: 2, rampAngleDegrees: 3), leadIn: linearLead, leadOut: nil)
        }
    }

    @Test("A lead-in with plunge and fromOpenEnd entries is accepted")
    func testLeadInWithPlungeIsFine() throws {
        #expect(!(try generate(entry: .plunge, leadIn: linearLead, leadOut: nil)).isEmpty)
        #expect(!(try generate(entry: .fromOpenEnd(stepoverPercentage: 0.5), leadIn: linearLead, leadOut: nil)).isEmpty)
    }

    @Test("Ramp and helix without a lead-in still work")
    func testRampAndHelixWithoutLeadIn() throws {
        #expect(!(try generate(entry: .ramp(angleDegrees: 3), leadIn: nil, leadOut: nil)).isEmpty)
        #expect(!(try generate(entry: .helix(radius: 2, rampAngleDegrees: 3), leadIn: nil, leadOut: nil)).isEmpty)
    }

    @Test("A lead-out is honored with ramp and helix entries: a feed move off the contour, then a retract above it")
    func testLeadOutWithRampAndHelix() throws {
        for entry in [SC.EntryStrategy.ramp(angleDegrees: 3), .helix(radius: 2, rampAngleDegrees: 3)] {
            let without = try generate(entry: entry, leadIn: nil, leadOut: nil)
            let with = try generate(entry: entry, leadIn: nil, leadOut: linearLead)

            for (pass, passWithout) in zip(with, without) {
                let retract = try #require(pass.waypoints.last)
                let leadOutMove = pass.waypoints[pass.waypoints.count - 2]

                // The lead-out is one extra feed move, at the lead-out feed rate and the pass depth.
                #expect(pass.waypoints.count == passWithout.waypoints.count + 1)
                #expect(leadOutMove.motion == .linear)
                #expect(leadOutMove.feedRate == linearLead.feedRate)
                #expect(leadOutMove.position.z == pass.depthZ)

                // It travels 2 mm off the contour end, and the retract rises straight up from there.
                let contourEnd = try #require(passWithout.waypoints.dropLast().last)
                let travelled = hypot(leadOutMove.position.x - contourEnd.position.x,
                                      leadOutMove.position.y - contourEnd.position.y)
                #expect(abs(travelled - 2) < 1e-9)

                #expect(retract.motion == .rapid)
                #expect(retract.position.x == leadOutMove.position.x)
                #expect(retract.position.y == leadOutMove.position.y)
                #expect(retract.position.z == settings.safeZ)
            }
        }
    }
}
