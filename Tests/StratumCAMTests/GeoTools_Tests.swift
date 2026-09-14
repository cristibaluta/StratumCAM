//
//  LineLineIntersectionTests.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 14.09.2026.
//

import Testing
import Foundation
@testable import StratumCAM

// MARK: - Helpers

/// Compares two CGPoints within a small tolerance to account for floating point error.
func expectPoint(_ actual: CGPoint, _ expected: CGPoint, tolerance: Double = 1e-6,
                  sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(actual.x - expected.x) < tolerance, "x mismatch: \(actual.x) vs \(expected.x)", sourceLocation: sourceLocation)
    #expect(abs(actual.y - expected.y) < tolerance, "y mismatch: \(actual.y) vs \(expected.y)", sourceLocation: sourceLocation)
}

/// Checks that `points` contains a point approximately equal to `expected`, regardless of order.
func expectContains(_ points: [CGPoint], _ expected: CGPoint, tolerance: Double = 1e-6,
                     sourceLocation: SourceLocation = #_sourceLocation) {
    let found = points.contains { abs($0.x - expected.x) < tolerance && abs($0.y - expected.y) < tolerance }
    #expect(found, "Expected to find point \(expected) in \(points)", sourceLocation: sourceLocation)
}

// MARK: - lineLineIntersection

@Suite("GeoTools.lineLineIntersection")
struct LineLineIntersectionTests {

    @Test("Two lines crossing at 45 degrees intersect at the expected point")
    func crossingLines() {
        let p1 = CGPoint(x: 0, y: 0)
        let p2 = CGPoint(x: 2, y: 2)
        let p3 = CGPoint(x: 0, y: 2)
        let p4 = CGPoint(x: 2, y: 0)

        let result = GeoTools.lineLineIntersection(p1, p2, p3, p4)

        #expect(result.count == 1)
        if let point = result.first {
            expectPoint(point, CGPoint(x: 1, y: 1))
        }
    }

    @Test("Perpendicular vertical and horizontal lines intersect correctly")
    func perpendicularLines() {
        let p1 = CGPoint(x: 0, y: 0)
        let p2 = CGPoint(x: 0, y: 5)
        let p3 = CGPoint(x: -3, y: 2)
        let p4 = CGPoint(x: 3, y: 2)

        let result = GeoTools.lineLineIntersection(p1, p2, p3, p4)

        #expect(result.count == 1)
        if let point = result.first {
            expectPoint(point, CGPoint(x: 0, y: 2))
        }
    }

    @Test("Parallel lines return no intersection")
    func parallelLines() {
        let p1 = CGPoint(x: 0, y: 0)
        let p2 = CGPoint(x: 1, y: 0)
        let p3 = CGPoint(x: 0, y: 1)
        let p4 = CGPoint(x: 1, y: 1)

        let result = GeoTools.lineLineIntersection(p1, p2, p3, p4)

        #expect(result.isEmpty)
    }

    @Test("Coincident (overlapping) lines are treated as parallel and return no intersection")
    func coincidentLines() {
        let p1 = CGPoint(x: 0, y: 0)
        let p2 = CGPoint(x: 4, y: 0)
        let p3 = CGPoint(x: 1, y: 0)
        let p4 = CGPoint(x: 5, y: 0)

        let result = GeoTools.lineLineIntersection(p1, p2, p3, p4)

        #expect(result.isEmpty)
    }

    @Test("Intersection point can lie outside both segments (treated as infinite lines)")
    func intersectionBeyondSegmentBounds() {
        // Segment 1: (0,0)-(1,0) horizontal. Segment 2: (2,-1)-(2,1) vertical, far to the right.
        let p1 = CGPoint(x: 0, y: 0)
        let p2 = CGPoint(x: 1, y: 0)
        let p3 = CGPoint(x: 2, y: -1)
        let p4 = CGPoint(x: 2, y: 1)

        let result = GeoTools.lineLineIntersection(p1, p2, p3, p4)

        #expect(result.count == 1)
        if let point = result.first {
            expectPoint(point, CGPoint(x: 2, y: 0))
        }
    }
}

// MARK: - circleLineIntersections

@Suite("GeoTools.circleLineIntersections")
struct CircleLineIntersectionTests {

    @Test("A line through the center intersects the circle at two diametrically opposite points")
    func lineThroughCenter() {
        let center = CGPoint(x: 0, y: 0)
        let radius = 5.0
        let p1 = CGPoint(x: -10, y: 0)
        let p2 = CGPoint(x: 10, y: 0)

        let result = GeoTools.circleLineIntersections(center: center, radius: radius, p1: p1, p2: p2)

        #expect(result.count == 2)
        expectContains(result, CGPoint(x: -5, y: 0))
        expectContains(result, CGPoint(x: 5, y: 0))
    }

    @Test("A tangent line touches the circle at exactly one point (returned twice)")
    func tangentLine() {
        let center = CGPoint(x: 0, y: 0)
        let radius = 5.0
        let p1 = CGPoint(x: -5, y: 5)
        let p2 = CGPoint(x: 5, y: 5)

        let result = GeoTools.circleLineIntersections(center: center, radius: radius, p1: p1, p2: p2)

        #expect(result.count == 2)
        for point in result {
            expectPoint(point, CGPoint(x: 0, y: 5))
        }
    }

    @Test("A line that misses the circle entirely returns no intersections")
    func lineMissesCircle() {
        let center = CGPoint(x: 0, y: 0)
        let radius = 1.0
        let p1 = CGPoint(x: -5, y: 10)
        let p2 = CGPoint(x: 5, y: 10)

        let result = GeoTools.circleLineIntersections(center: center, radius: radius, p1: p1, p2: p2)

        #expect(result.isEmpty)
    }

    @Test("A degenerate line (p1 == p2) returns no intersections")
    func degenerateLine() {
        let center = CGPoint(x: 0, y: 0)
        let radius = 5.0
        let p1 = CGPoint(x: 1, y: 1)
        let p2 = CGPoint(x: 1, y: 1)

        let result = GeoTools.circleLineIntersections(center: center, radius: radius, p1: p1, p2: p2)

        #expect(result.isEmpty)
    }

    @Test("A chord not passing through the center yields two distinct points on the circle")
    func offCenterChord() {
        let center = CGPoint(x: 0, y: 0)
        let radius = 5.0
        let p1 = CGPoint(x: -10, y: 3)
        let p2 = CGPoint(x: 10, y: 3)

        let result = GeoTools.circleLineIntersections(center: center, radius: radius, p1: p1, p2: p2)

        #expect(result.count == 2)
        expectContains(result, CGPoint(x: -4, y: 3))
        expectContains(result, CGPoint(x: 4, y: 3))
    }
}

// MARK: - circleCircleIntersections

@Suite("GeoTools.circleCircleIntersections")
struct CircleCircleIntersectionTests {

    @Test("Two overlapping circles of equal radius intersect at two symmetric points")
    func overlappingEqualCircles() {
        let c1 = CGPoint(x: 0, y: 0)
        let r1 = 5.0
        let c2 = CGPoint(x: 8, y: 0)
        let r2 = 5.0

        let result = GeoTools.circleCircleIntersections(c1: c1, r1: r1, c2: c2, r2: r2)

        #expect(result.count == 2)
        expectContains(result, CGPoint(x: 4, y: 3))
        expectContains(result, CGPoint(x: 4, y: -3))
    }

    @Test("Externally tangent circles touch at exactly one point (returned twice)")
    func externallyTangentCircles() {
        let c1 = CGPoint(x: 0, y: 0)
        let r1 = 3.0
        let c2 = CGPoint(x: 6, y: 0)
        let r2 = 3.0

        let result = GeoTools.circleCircleIntersections(c1: c1, r1: r1, c2: c2, r2: r2)

        #expect(result.count == 2)
        for point in result {
            expectPoint(point, CGPoint(x: 3, y: 0))
        }
    }

    @Test("Circles too far apart to touch return no intersections")
    func circlesTooFarApart() {
        let c1 = CGPoint(x: 0, y: 0)
        let r1 = 1.0
        let c2 = CGPoint(x: 10, y: 0)
        let r2 = 1.0

        let result = GeoTools.circleCircleIntersections(c1: c1, r1: r1, c2: c2, r2: r2)

        #expect(result.isEmpty)
    }

    @Test("One circle fully inside another with no touching returns no intersections")
    func oneCircleFullyInsideAnother() {
        let c1 = CGPoint(x: 0, y: 0)
        let r1 = 10.0
        let c2 = CGPoint(x: 1, y: 0)
        let r2 = 1.0

        let result = GeoTools.circleCircleIntersections(c1: c1, r1: r1, c2: c2, r2: r2)

        #expect(result.isEmpty)
    }

    @Test("Concentric circles (zero center distance) return no intersections")
    func concentricCircles() {
        let c1 = CGPoint(x: 0, y: 0)
        let r1 = 1.0
        let c2 = CGPoint(x: 0, y: 0)
        let r2 = 2.0

        let result = GeoTools.circleCircleIntersections(c1: c1, r1: r1, c2: c2, r2: r2)

        #expect(result.isEmpty)
    }

    @Test("Internally tangent circles touch at exactly one point (returned twice)")
    func internallyTangentCircles() {
        let c1 = CGPoint(x: 0, y: 0)
        let r1 = 10.0
        let c2 = CGPoint(x: 4, y: 0)
        let r2 = 6.0

        let result = GeoTools.circleCircleIntersections(c1: c1, r1: r1, c2: c2, r2: r2)

        #expect(result.count == 2)
        for point in result {
            expectPoint(point, CGPoint(x: 10, y: 0))
        }
    }
}
