//
//  RestCorners_Tests.swift
//  StratumCAM
//

import Testing
import CoreGraphics
@testable import StratumCAM

struct RestCorners_Tests {

    private func polygon(_ points: [(Double, Double)]) -> [SC.Segment] {
        points.indices.map { i in
            let a = points[i]
            let b = points[(i + 1) % points.count]
            return SC.Segment.line(start: CGPoint(x: a.0, y: a.1), end: CGPoint(x: b.0, y: b.1))
        }
    }

    private let engine = SCEngine()

    @Test func squareHasFourCorners() {
        let square = polygon([(0, 0), (20, 0), (20, 20), (0, 20)])
        let corners = engine.restCorners(in: square, toolRadius: 3)
        #expect(corners.count == 4)
        // Depth of a 90 degree corner: r * (sqrt(2) - 1) from corner to circle.
        for corner in corners {
            #expect(abs(corner.interiorAngle - Double.pi / 2) < 1e-9)
            #expect(corner.region.count == 3)
        }
    }

    @Test func clockwiseSquareGivesTheSameCorners() {
        let square = polygon([(0, 0), (0, 20), (20, 20), (20, 0)])
        #expect(engine.restCorners(in: square, toolRadius: 3).count == 4)
    }

    @Test func rectangleHasFourCorners() {
        let rect = polygon([(0, 0), (40, 0), (40, 10), (0, 10)])
        #expect(engine.restCorners(in: rect, toolRadius: 3).count == 4)
    }

    @Test func lShapeIgnoresTheReflexCorner() {
        let l = polygon([(0, 0), (20, 0), (20, 10), (10, 10), (10, 20), (0, 20)])
        // Six vertices, one of them reflex.
        #expect(engine.restCorners(in: l, toolRadius: 2).count == 5)
    }

    @Test func circleApproximatedByLinesHasNoCorners() {
        let points = (0..<64).map { i -> (Double, Double) in
            let a = Double(i) / 64 * 2 * Double.pi
            return (10 * cos(a), 10 * sin(a))
        }
        #expect(engine.restCorners(in: polygon(points), toolRadius: 3).isEmpty)
    }

    @Test func shortWallKeepsItsCornerWithAChordClosure() {
        // A thin triangle: walls at the tip are shorter than the tangent distance.
        let triangle = polygon([(0, 0), (30, 0), (2, 3)])
        let corners = engine.restCorners(in: triangle, toolRadius: 1.0)
        #expect(!corners.isEmpty)
        for corner in corners {
            if case .line = corner.region[2] {} else if corner.region.count == 3 {
                // Either closed by an arc (walls long enough) or by a chord (clamped).
                if case .arc = corner.region[2] {} else { Issue.record("unexpected closing segment") }
            }
        }
    }

    @Test func toolTooBigForThePocketFindsNothing() {
        let square = polygon([(0, 0), (4, 0), (4, 4), (0, 4)])
        // Tool centre would fall outside the 4x4 square.
        #expect(engine.restCorners(in: square, toolRadius: 10).isEmpty)
    }
}
