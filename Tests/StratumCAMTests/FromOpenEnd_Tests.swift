//
//  FromOpenEnd_Tests.swift
//  StratumCAM
//
//  `.fromOpenEnd` only has its own trochoidal feed-in inside `.slotting`. On `.contour` and
//  `.pocket` it used to emit no entry moves at all, so the first cutting move started from
//  wherever the tool happened to be. There it now means "the start is in free air": rapid
//  above the start, then drop straight down -- the same moves as `.plunge`.
//

import Testing
import Foundation
@testable import StratumCAM

struct FromOpenEnd_Tests {

    private let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 0.5),
                                              safeZ: 5,
                                              targetDepth: -1)

    private func rectangle() -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(20, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(20, 0), b: SIMD2<Double>(20, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(20, 10), b: SIMD2<Double>(0, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, 10), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true)
    }

    private func openLine() -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(20, 0)), reversed: false)
        ], isClosed: false)
    }

    private func contourOperation(side: SC.CutSide, entry: SC.EntryStrategy) -> SC.MachiningOperation {
        .contour(side: side, direction: .conventional, entry: entry, leadIn: nil, leadOut: nil, tabs: [])
    }

    private func passes(_ contour: SC.Contour, _ operation: SC.MachiningOperation, tool: Double = 3) throws -> [SC.ToolpathPass] {
        let paths = try SCEngine().generateToolpaths(from: [contour],
                                                     tool: SC.ToolParams(diameter: tool),
                                                     settings: settings,
                                                     operation: operation)
        return try #require(paths.first).passes
    }

    @Test("Contour .fromOpenEnd starts every pass with a rapid above the start and a plunge to depth")
    func testContourEntryMoves() throws {
        let result = try passes(openLine(), contourOperation(side: .onContour, entry: .fromOpenEnd(stepoverPercentage: 0.5)))

        #expect(!result.isEmpty)
        for pass in result {
            let first = try #require(pass.waypoints.first)
            let second = try #require(pass.waypoints.dropFirst().first)

            #expect(first.motion == .rapid)
            #expect(first.position == SIMD3(0, 0, settings.safeZ))

            #expect(second.motion == .linear)
            #expect(second.position == SIMD3(0, 0, pass.depthZ))
            #expect(second.feedRate == settings.cutting.plungeRate)
        }
    }

    @Test("Contour .fromOpenEnd produces the same toolpath as .plunge, open and closed")
    func testContourMatchesPlunge() throws {
        for contour in [openLine(), rectangle()] {
            for side in [SC.CutSide.onContour, .outside] {
                let open = try passes(contour, contourOperation(side: side, entry: .fromOpenEnd(stepoverPercentage: 0.5)))
                let plunge = try passes(contour, contourOperation(side: side, entry: .plunge))

                #expect(open.map(\.waypoints) == plunge.map(\.waypoints))
            }
        }
    }

    @Test("Contour .fromOpenEnd honors a lead-in like .plunge does")
    func testContourLeadIn() throws {
        let leadIn = SC.LeadInOut(style: .linear(length: 2), feedRate: 400)
        let open = try passes(rectangle(), .contour(side: .outside, direction: .conventional,
                                                    entry: .fromOpenEnd(stepoverPercentage: 0.5),
                                                    leadIn: leadIn, leadOut: leadIn, tabs: []))
        let plunge = try passes(rectangle(), .contour(side: .outside, direction: .conventional,
                                                      entry: .plunge,
                                                      leadIn: leadIn, leadOut: leadIn, tabs: []))

        #expect(open.map(\.waypoints) == plunge.map(\.waypoints))
    }

    @Test("Pocket .fromOpenEnd matches .plunge instead of starting mid-air")
    func testPocketMatchesPlunge() throws {
        let tool = 6.0
        let open = try passes(rectangle(), .pocket(direction: .conventional, pattern: .offset, entry: .fromOpenEnd(stepoverPercentage: 0.5)), tool: tool)
        let plunge = try passes(rectangle(), .pocket(direction: .conventional, pattern: .offset, entry: .plunge), tool: tool)

        #expect(!open.isEmpty)
        #expect(open.map(\.waypoints) == plunge.map(\.waypoints))

        // Every pass begins above the ring start and drops to its depth.
        for pass in open {
            #expect(pass.waypoints[0].motion == .rapid)
            #expect(pass.waypoints[1].motion == .linear)
            #expect(pass.waypoints[1].position.z == pass.depthZ)
        }
    }

    @Test("Slotting .fromOpenEnd keeps its own behaviour (isStraightDown only affects contour/pocket)")
    func testIsStraightDown() {
        #expect(SC.EntryStrategy.plunge.isStraightDown)
        #expect(SC.EntryStrategy.fromOpenEnd(stepoverPercentage: 0.5).isStraightDown)
        #expect(!SC.EntryStrategy.ramp(angleDegrees: 3).isStraightDown)
        #expect(!SC.EntryStrategy.helix(radius: 2, rampAngleDegrees: 3).isStraightDown)
    }
}
