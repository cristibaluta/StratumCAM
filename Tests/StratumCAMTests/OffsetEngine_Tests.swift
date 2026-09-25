//
//  OffsetEngine_Tests.swift
//  StratumCAM
//

import Testing
import CoreGraphics
@testable import StratumCAM

struct OffsetEngine_Tests {

    // A 10x10 CCW square: (0,0) -> (10,0) -> (10,10) -> (0,10) -> back to (0,0)
    private func ccwSquare() -> [SC.Segment] {
        [
            .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 0)),
            .line(start: CGPoint(x: 10, y: 0), end: CGPoint(x: 10, y: 10)),
            .line(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 0, y: 10)),
            .line(start: CGPoint(x: 0, y: 10), end: CGPoint(x: 0, y: 0))
        ]
    }

    @Test func testLineOffsetShiftsPerpendicular() {
        let line = SC.Segment.line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 0))
        let offset = line.offset(by: 1.0)
        guard case let .line(start, end) = offset else {
            Issue.record("Expected a line segment")
            return
        }
        // Left of travelling +x is +y
        #expect(abs(start.y - 1.0) < 1e-9)
        #expect(abs(end.y - 1.0) < 1e-9)
    }

    @Test func testArcOffsetShrinksOnLeftForCCWArc() {
        let arc = SC.Segment.arc(center: CGPoint(x: 0, y: 0), radius: 5, startAngle: 0, endAngle: .pi, isCCW: true)
        let offset = arc.offset(by: 1.0)
        guard case let .arc(_, radius, _, _, _) = offset else {
            Issue.record("Expected an arc segment")
            return
        }
        #expect(abs(radius - 4.0) < 1e-9)
    }

    @Test func testArcOffsetCollapsesWhenToolTooBig() {
        let arc = SC.Segment.arc(center: CGPoint(x: 0, y: 0), radius: 2, startAngle: 0, endAngle: .pi, isCCW: true)
        #expect(arc.offset(by: 5.0) == nil)
    }

    @Test func testOutsideOffsetOfCCWSquareAddsFilletsAndGrowsIt() {
        let engine = SCEngine()
        let result = engine.offsetContour(ccwSquare(), side: .outside, toolRadius: 1.0, isClosed: true)

        // 4 original lines + 4 corner fillets
        #expect(result.count == 8)

        // The bottom edge should have moved outward (down) by 1
        guard case let .line(start, end) = result[0] else {
            Issue.record("Expected first segment to remain a line")
            return
        }
        #expect(abs(start.y - (-1.0)) < 1e-6)
        #expect(abs(end.y - (-1.0)) < 1e-6)

        // Every fillet should carry the tool radius
        let fillets = result.compactMap { segment -> Double? in
            if case let .arc(_, radius, _, _, _) = segment { return radius }
            return nil
        }
        #expect(fillets.count == 4)
        for radius in fillets {
            #expect(abs(radius - 1.0) < 1e-6)
        }
    }

    @Test func testInsideOffsetOfCCWSquareStaysSharpAndShrinksIt() {
        let engine = SCEngine()
        let result = engine.offsetContour(ccwSquare(), side: .inside, toolRadius: 1.0, isClosed: true)

        // Convex corners trimmed to a sharp point when offsetting inward -- no fillets
        #expect(result.count == 4)

        guard case let .line(start, end) = result[0] else {
            Issue.record("Expected first segment to remain a line")
            return
        }
        // Bottom edge moved inward (up) by 1, and trimmed to meet the (now inset) side walls
        #expect(abs(start.y - 1.0) < 1e-6)
        #expect(abs(end.y - 1.0) < 1e-6)
        #expect(abs(start.x - 1.0) < 1e-6)   // trimmed to meet the inset left wall
        #expect(abs(end.x - 9.0) < 1e-6)     // trimmed to meet the inset right wall
    }

    @Test func testOnContourSideIsANoOp() {
        let engine = SCEngine()
        let square = ccwSquare()
        let result = engine.offsetContour(square, side: .onContour, toolRadius: 1.0, isClosed: true)
        #expect(result == square)
    }

    // Regression test for the "toolpath went crazy" bug: a sharp, near-reversing
    // concave notch (a 1-degree half-angle spike -- the kind of tight cusp you get at
    // the pinched "neck" of a figure-8/keyring pendant) meeting at the origin.
    //
    // `intersectionCandidates` treats both adjacent offset segments as infinite lines.
    // For a genuine miter join, the trim point sits at distance / sin(halfAngle) from
    // the vertex -- for a 1-degree spike that's over 57x the tool radius. Before the
    // fix, that wild point got spliced straight into the toolpath (the long spiking,
    // self-crossing loops seen at the neck in the reported bug). The fix rejects any
    // trim candidate unreasonably far from the vertex and bridges the gap with a short
    // straight line instead.
    @Test func testSharpConcaveSpikeDoesNotProduceWildMiterPoint() {
        let engine = SCEngine()

        let halfAngle = 1.0 * Double.pi / 180.0
        let a = CGPoint(x: -5 * sin(halfAngle), y: 5 * cos(halfAngle))
        let v = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 5 * sin(halfAngle), y: 5 * cos(halfAngle))

        let segments: [SC.Segment] = [.line(start: a, end: v), .line(start: v, end: b)]

        // .inside on this open 2-segment chain resolves to the concave/trim branch at
        // the vertex -- the same branch that mishandled the pendant's neck.
        let result = engine.offsetContour(segments, side: .inside, toolRadius: 1.0, isClosed: false)

        // Nothing in the result should be extrapolated dozens of units from the vertex --
        // the old bug placed a point ~57 units away for this exact geometry.
        for segment in result {
            #expect(hypot(segment.startPoint.x - v.x, segment.startPoint.y - v.y) < 5.0)
            #expect(hypot(segment.endPoint.x - v.x, segment.endPoint.y - v.y) < 5.0)
        }

        // The corner should have been bridged with a short straight line (3 segments:
        // seg0, bridge, seg1) instead of trimmed to a single wild extrapolated point.
        #expect(result.count == 3)
    }
}
