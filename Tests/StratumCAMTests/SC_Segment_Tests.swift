//
//  SC.Segment.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 14.09.2026.
//

import Testing
import Foundation
@testable import StratumCAM

@Suite("PathSegment.pathLength")
struct PathSegmentPathLengthTests {

    // MARK: - .line

    @Test("Horizontal line returns the horizontal distance")
    func horizontalLine() {
        let segment = SC.Segment.line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 5, y: 0))
        #expect(segment.pathLength ~= 5)
    }

    @Test("Vertical line returns the vertical distance")
    func verticalLine() {
        let segment = SC.Segment.line(start: CGPoint(x: 2, y: 2), end: CGPoint(x: 2, y: -3))
        #expect(segment.pathLength ~= 5)
    }

    @Test("Diagonal line returns the straight-line (Euclidean) distance")
    func diagonalLine() {
        // 3-4-5 triangle
        let segment = SC.Segment.line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 3, y: 4))
        #expect(segment.pathLength ~= 5)
    }

    @Test("Zero-length line (identical start and end) returns zero")
    func zeroLengthLine() {
        let segment = SC.Segment.line(start: CGPoint(x: 1, y: 1), end: CGPoint(x: 1, y: 1))
        #expect(segment.pathLength ~= 0)
    }

    @Test("Line with negative coordinates still returns the correct distance")
    func negativeCoordinatesLine() {
        let segment = SC.Segment.line(start: CGPoint(x: -3, y: -4), end: CGPoint(x: 0, y: 0))
        #expect(segment.pathLength ~= 5)
    }

    // MARK: - .arc

    @Test("Quarter-circle arc returns radius * (π/2)")
    func quarterCircleArc() {
        let segment = SC.Segment.arc(
            center: CGPoint(x: 0, y: 0),
            radius: 10,
            startAngle: 0,
            endAngle: .pi / 2,
            isCCW: true
        )
        let expected: Double = 10 * (.pi / 2)
        #expect(segment.pathLength ~= expected)
    }

    @Test("Half-circle arc returns radius * π")
    func halfCircleArc() {
        let segment = SC.Segment.arc(
            center: CGPoint(x: 0, y: 0),
            radius: 4,
            startAngle: 0,
            endAngle: .pi,
            isCCW: false
        )
        let expected = 4 * Double.pi
        #expect(segment.pathLength ~= expected)
    }

    @Test("Full-circle arc (sweep of 2π) returns the full circumference")
    func fullCircleArc() {
        let segment = SC.Segment.arc(
            center: CGPoint(x: 0, y: 0),
            radius: 3,
            startAngle: 0,
            endAngle: 2 * .pi,
            isCCW: true
        )
        let expected = 3 * (2 * Double.pi)
        #expect(segment.pathLength ~= expected)
    }

    @Test("Negative sweep (endAngle before startAngle) is measured as a positive length")
    func negativeSweepArc() {
        let segment = SC.Segment.arc(
            center: CGPoint(x: 0, y: 0),
            radius: 5,
            startAngle: .pi,
            endAngle: 0,
            isCCW: true
        )
        let expected = 5 * Double.pi
        #expect(segment.pathLength ~= expected)
    }

    @Test("Zero sweep (startAngle == endAngle) returns zero length regardless of radius")
    func zeroSweepArc() {
        let segment = SC.Segment.arc(
            center: CGPoint(x: 1, y: 1),
            radius: 7,
            startAngle: .pi / 4,
            endAngle: .pi / 4,
            isCCW: false
        )
        #expect(segment.pathLength ~= 0)
    }

    @Test("Sweep greater than a full turn accumulates length beyond one circumference")
    func multiTurnArc() {
        let segment = SC.Segment.arc(
            center: CGPoint(x: 0, y: 0),
            radius: 2,
            startAngle: 0,
            endAngle: 3 * .pi, // 1.5 full turns
            isCCW: true
        )
        let expected = 2 * (3 * Double.pi)
        #expect(segment.pathLength ~= expected)
    }

    @Test("Zero radius arc returns zero length regardless of sweep")
    func zeroRadiusArc() {
        let segment = SC.Segment.arc(
            center: CGPoint(x: 0, y: 0),
            radius: 0,
            startAngle: 0,
            endAngle: .pi,
            isCCW: false
        )
        #expect(segment.pathLength ~= 0)
    }

    @Test("Arc length is unaffected by the center point's position")
    func centerPositionDoesNotAffectLength() {
        let segmentA = SC.Segment.arc(
            center: CGPoint(x: 0, y: 0),
            radius: 6,
            startAngle: 0,
            endAngle: .pi / 3,
            isCCW: false
        )
        let segmentB = SC.Segment.arc(
            center: CGPoint(x: 100, y: -50),
            radius: 6,
            startAngle: 0,
            endAngle: .pi / 3,
            isCCW: false
        )
        #expect(segmentA.pathLength ~= segmentB.pathLength)
    }
}
