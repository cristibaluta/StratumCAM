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
}
