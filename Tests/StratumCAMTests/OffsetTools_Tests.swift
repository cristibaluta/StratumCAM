//
//  differs.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 14.09.2026.
//

import Testing
import Foundation
@testable import StratumCAM

@Suite("OffsetTools")
struct OffsetTools_Tests {

    // MARK: - Fixtures

    /// A unit square traced counter-clockwise: (0,0) -> (4,0) -> (4,4) -> (0,4) -> close.
    private var ccwSquareSegments: [SC.Segment] {
        [
            .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 4, y: 0)),
            .line(start: CGPoint(x: 4, y: 0), end: CGPoint(x: 4, y: 4)),
            .line(start: CGPoint(x: 4, y: 4), end: CGPoint(x: 0, y: 4)),
            .line(start: CGPoint(x: 0, y: 4), end: CGPoint(x: 0, y: 0))
        ]
    }

    /// The same square traced clockwise: (0,0) -> (0,4) -> (4,4) -> (4,0) -> close.
    private var cwSquareSegments: [SC.Segment] {
        [
            .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 4)),
            .line(start: CGPoint(x: 0, y: 4), end: CGPoint(x: 4, y: 4)),
            .line(start: CGPoint(x: 4, y: 4), end: CGPoint(x: 4, y: 0)),
            .line(start: CGPoint(x: 4, y: 0), end: CGPoint(x: 0, y: 0))
        ]
    }

    // MARK: - offsetDistance: .onContour

    @Test("onContour always returns zero, regardless of tool radius or winding")
    func onContourAlwaysZero() {
        #expect(OffsetTools.offsetDistance(for: .onContour, toolRadius: 3, segments: ccwSquareSegments) == 0)
        #expect(OffsetTools.offsetDistance(for: .onContour, toolRadius: 3, segments: cwSquareSegments) == 0)
        #expect(OffsetTools.offsetDistance(for: .onContour, toolRadius: 0, segments: []) == 0)
    }

    // MARK: - offsetDistance: .outside

    @Test("outside on a CCW contour returns a negative offset equal to -toolRadius")
    func outsideOnCCWContour() {
        let distance = OffsetTools.offsetDistance(for: .outside, toolRadius: 2.5, segments: ccwSquareSegments)
        #expect(abs(distance + 2.5) < 1e-9)
    }

    @Test("outside on a CW contour returns a positive offset equal to +toolRadius")
    func outsideOnCWContour() {
        let distance = OffsetTools.offsetDistance(for: .outside, toolRadius: 2.5, segments: cwSquareSegments)
        #expect(abs(distance - 2.5) < 1e-9)
    }

    // MARK: - offsetDistance: .inside

    @Test("inside on a CCW contour returns a positive offset equal to +toolRadius")
    func insideOnCCWContour() {
        let distance = OffsetTools.offsetDistance(for: .inside, toolRadius: 1.75, segments: ccwSquareSegments)
        #expect(abs(distance - 1.75) < 1e-9)
    }

    @Test("inside on a CW contour returns a negative offset equal to -toolRadius")
    func insideOnCWContour() {
        let distance = OffsetTools.offsetDistance(for: .inside, toolRadius: 1.75, segments: cwSquareSegments)
        #expect(abs(distance - (-1.75)) < 1e-9)
    }

    @Test("A zero tool radius always yields a zero offset, regardless of side or winding")
    func zeroToolRadiusYieldsZeroOffset() {
        #expect(OffsetTools.offsetDistance(for: .inside, toolRadius: 0, segments: ccwSquareSegments) == 0)
        #expect(OffsetTools.offsetDistance(for: .outside, toolRadius: 0, segments: cwSquareSegments) == 0)
    }

    // MARK: - isCCWWinding: lines

    @Test("A square traced counter-clockwise is detected as CCW")
    func squareTracedCCW() {
        #expect(OffsetTools.isCCWWinding(ccwSquareSegments) == true)
    }

    @Test("A square traced clockwise is detected as not CCW")
    func squareTracedCW() {
        #expect(OffsetTools.isCCWWinding(cwSquareSegments) == false)
    }

    // MARK: - isCCWWinding: arcs

    @Test("A full circle swept counter-clockwise (increasing angle) is detected as CCW")
    func fullCircleSweptCCW() {
        let segments: [SC.Segment] = [
            .arc(center: CGPoint(x: 0, y: 0), radius: 5, startAngle: 0, endAngle: 2 * Double.pi, isCCW: true)
        ]
        #expect(OffsetTools.isCCWWinding(segments) == true)
    }

    @Test("A full circle swept clockwise (decreasing angle) is detected as not CCW")
    func fullCircleSweptCW() {
        let segments: [SC.Segment] = [
            .arc(center: CGPoint(x: 0, y: 0), radius: 5, startAngle: 2 * Double.pi, endAngle: 0, isCCW: false)
        ]
        #expect(OffsetTools.isCCWWinding(segments) == false)
    }

    // MARK: - isCCWWinding: degenerate inputs

    @Test("An empty segment list defaults to CCW (fewer than 3 sampled points)")
    func emptySegmentsDefaultsToCCW() {
        #expect(OffsetTools.isCCWWinding([]) == true)
    }

    @Test("A single line segment (one sampled point) defaults to CCW")
    func singleLineSegmentDefaultsToCCW() {
        let segments: [SC.Segment] = [
            .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1))
        ]
        #expect(OffsetTools.isCCWWinding(segments) == true)
    }

    @Test("Two line segments (two sampled points) still default to CCW")
    func twoLineSegmentsDefaultToCCW() {
        let segments: [SC.Segment] = [
            .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 0)),
            .line(start: CGPoint(x: 1, y: 0), end: CGPoint(x: 1, y: 1))
        ]
        #expect(OffsetTools.isCCWWinding(segments) == true)
    }

    // MARK: - isCCWWinding: mixed line/arc contour

    @Test("A D-shaped contour (diameter + CCW semicircle) enclosing area above the diameter is detected as CCW")
    func dShapeContourCCW() {
        // Travels right-to-left along the diameter, then back over the top via a CCW arc,
        // enclosing the upper half-disk while sweeping counter-clockwise overall.
        let segments: [SC.Segment] = [
            .line(start: CGPoint(x: 5, y: 0), end: CGPoint(x: -5, y: 0)),
            .arc(center: CGPoint(x: 0, y: 0), radius: 5, startAngle: Double.pi, endAngle: 2 * Double.pi, isCCW: true)
        ]
        #expect(OffsetTools.isCCWWinding(segments) == true)
    }
}
