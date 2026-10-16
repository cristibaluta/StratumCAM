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
        #expect(start.y ~= 1.0)
        #expect(end.y ~= 1.0)
    }

    @Test func testArcOffsetShrinksOnLeftForCCWArc() {
        let arc = SC.Segment.arc(center: CGPoint(x: 0, y: 0), radius: 5, startAngle: 0, endAngle: .pi, isCCW: true)
        let offset = arc.offset(by: 1.0)
        guard case let .arc(_, radius, _, _, _) = offset else {
            Issue.record("Expected an arc segment")
            return
        }
        #expect(radius ~= 4.0)
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
        #expect(start.y ~= -1.0)
        #expect(end.y ~= -1.0)

        // Every fillet should carry the tool radius
        let fillets = result.compactMap { segment -> Double? in
            if case let .arc(_, radius, _, _, _) = segment { return radius }
            return nil
        }
        #expect(fillets.count == 4)
        for radius in fillets {
            #expect(radius ~= 1.0)
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
        #expect(start.y ~= 1.0)
        #expect(end.y ~= 1.0)
        #expect(start.x ~= 1.0)   // trimmed to meet the inset left wall
        #expect(end.x ~= 9.0)     // trimmed to meet the inset right wall
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

        // The corner should be bridged with a tool-radius arc pivoting around the
        // original vertex `v` (3 segments: seg0, arc, seg1) -- not trimmed to a single
        // wild extrapolated point (the old bug placed one ~57 units from the vertex
        // for this exact geometry) and not a straight-line shortcut across the notch
        // either (which would cut across it instead of following it).
        #expect(result.count == 3)
        guard case let .arc(center, radius, _, _, _) = result[1] else {
            Issue.record("expected the middle segment to be a pivot arc, got \(result[1])")
            return
        }
        #expect(hypot(center.x - v.x, center.y - v.y) < 1e-6)
        #expect(radius ~= 1.0)

        // Every point in the result should stay near the tool radius from the vertex --
        // nothing extrapolated dozens of units away.
        for segment in result {
            #expect(hypot(segment.startPoint.x - v.x, segment.startPoint.y - v.y) < 5.0)
            #expect(hypot(segment.endPoint.x - v.x, segment.endPoint.y - v.y) < 5.0)
        }
    }

    // MARK: - Shapes the exact offset can't handle (necks, splitting shapes, tool too big)

    /// Two 10x10 squares joined by a 10-long, 2-wide neck, counter-clockwise.
    private func dumbbell() -> [SC.Segment] {
        let points: [(Double, Double)] = [
            (0, 0), (10, 0), (10, 4), (20, 4), (20, 0), (30, 0),
            (30, 10), (20, 10), (20, 6), (10, 6), (10, 10), (0, 10)
        ]
        return points.indices.map { (i: Int) -> SC.Segment in
            let a = points[i]
            let b = points[(i + 1) % points.count]
            return .line(start: CGPoint(x: a.0, y: a.1), end: CGPoint(x: b.0, y: b.1))
        }
    }

    /// Shortest distance from `p` to any line segment of `polygon`.
    private func distance(from p: CGPoint, toPolygon polygon: [SC.Segment]) -> Double {
        var best = Double.infinity
        for case let .line(a, b) in polygon {
            let dx = b.x - a.x, dy = b.y - a.y
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
            best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
        }
        return best
    }

    // The 2 mm neck is narrower than a 4 mm tool, so the inside offset must not cross it:
    // the shape splits into one loop per square, and no point of either loop may come
    // closer than the tool radius to the original outline (that would be a bit collision).
    @Test func testNeckNarrowerThanToolSplitsInsideOffsetIntoTwoLoops() {
        let engine = SCEngine()
        let outline = dumbbell()
        let loops = engine.offsetContours(outline, side: .inside, toolRadius: 2.0, isClosed: true)

        #expect(loops.count == 2)

        var sawLeft = false
        var sawRight = false
        for loop in loops {
            let xs = loop.map { $0.startPoint.x }
            let isLeft = xs.allSatisfy { $0 < 10 }
            let isRight = xs.allSatisfy { $0 > 20 }
            #expect(isLeft || isRight, "a loop crossed the neck")
            sawLeft = sawLeft || isLeft
            sawRight = sawRight || isRight

            for segment in loop {
                #expect(distance(from: segment.startPoint, toPolygon: outline) > 2.0 - 0.02)
            }
        }
        #expect(sawLeft && sawRight)
    }

    // `offsetContour` still returns a single chain: the largest loop, not the input.
    @Test func testOffsetContourReturnsOneLoopForASplitShape() {
        let engine = SCEngine()
        let outline = dumbbell()
        let result = engine.offsetContour(outline, side: .inside, toolRadius: 2.0, isClosed: true)

        #expect(result != outline)
        let xs = result.map { $0.startPoint.x }
        #expect(xs.allSatisfy { $0 < 10 } || xs.allSatisfy { $0 > 20 })
    }

    // Outside, the tool just goes round the whole dumbbell: one loop, every vertex exactly
    // one tool radius from the outline.
    @Test func testOutsideOffsetOfDumbbellIsOneLoopAtToolRadius() {
        let engine = SCEngine()
        let outline = dumbbell()
        let loops = engine.offsetContours(outline, side: .outside, toolRadius: 2.0, isClosed: true)

        #expect(loops.count == 1)
        for segment in loops.first ?? [] {
            #expect(abs(distance(from: segment.startPoint, toPolygon: outline) - 2.0) < 0.02)
        }
    }

    // A tool wider than the whole shape fits nowhere: no loops (the contour operation turns
    // this into `geometryCollapsed`), and `offsetContour` keeps its "tool too big" contract of
    // handing the input back unchanged.
    @Test func testToolLargerThanShapeYieldsNoLoops() {
        let engine = SCEngine()
        let square = ccwSquare()

        #expect(engine.offsetContours(square, side: .inside, toolRadius: 6.0, isClosed: true).isEmpty)
        #expect(engine.offsetContour(square, side: .inside, toolRadius: 6.0, isClosed: true) == square)
    }

    // A valid offset keeps its true arcs: the polygon fallback must only kick in when the
    // exact construction is wrong.
    @Test func testValidOffsetKeepsExactArcs() {
        let engine = SCEngine()
        let loops = engine.offsetContours(ccwSquare(), side: .outside, toolRadius: 1.0, isClosed: true)

        #expect(loops.count == 1)
        let arcCount = (loops.first ?? []).filter {
            if case .arc = $0 { return true }
            return false
        }.count
        #expect(arcCount == 4)
    }
}
