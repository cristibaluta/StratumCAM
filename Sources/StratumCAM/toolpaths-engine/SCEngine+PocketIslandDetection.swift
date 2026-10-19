//
//  SCEngine+PocketIslandDetection.swift
//  StratumCAM
//
//  Automatic island detection for pockets. Callers hand `generateToolpaths` a flat list
//  of closed shapes; this works out which shapes sit inside which, so nobody has to
//  fill in `SC.Contour.islands` by hand.
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// Sorts a flat list of contours into pockets and islands using even-odd nesting:
    ///
    /// - A closed contour that is not inside any other closed contour is a pocket.
    /// - A closed contour inside one pocket (nesting depth 1) is an island of it.
    /// - A closed contour inside an island (depth 2) is material to remove again, so it is
    ///   a pocket of its own; depth 3 is an island of that pocket, and so on.
    ///
    /// The result has one entry per pocket (islands are folded into their parent's
    /// `islands`, appended after any islands the caller already set by hand), in the
    /// order the pockets appeared in the input. Open contours are passed through
    /// untouched, so `buildPocketToolpath` still reports `contourNotClosed` for them.
    ///
    /// Containment means every sampled point of the inner contour lies inside the outer
    /// one. Contours that cross each other are not nested and stay independent pockets.
    func resolvePocketIslands(_ contours: [SC.Contour]) -> [SC.Contour] {

        guard contours.count > 1 else {
            return contours
        }

        struct Shape {
            let index: Int
            let segments: [SC.Segment]
            let samples: [CGPoint]
            let box: (minX: Double, maxX: Double, minY: Double, maxY: Double)
            let area: Double
        }

        // Only closed contours with real geometry take part in nesting.
        var shapes: [Shape] = []
        for (index, contour) in contours.enumerated() where contour.isClosed {
            let segments = contour.linearizedSegments
            guard !segments.isEmpty else {
                continue
            }
            let polygon = nestingPolygon(of: segments)
            guard polygon.count >= 3 else {
                continue
            }
            shapes.append(Shape(index: index,
                                segments: segments,
                                samples: nestingSamples(of: segments),
                                box: segments.boundingBox,
                                area: abs(PolygonOffset.signedArea(polygon))))
        }

        guard shapes.count > 1 else {
            return contours
        }

        /// True when `inner` lies fully inside `outer`.
        func isInside(_ inner: Shape, _ outer: Shape) -> Bool {
            let tol = 1e-9
            guard outer.area > inner.area + tol else {
                return false
            }
            guard inner.box.minX >= outer.box.minX - tol, inner.box.maxX <= outer.box.maxX + tol,
                  inner.box.minY >= outer.box.minY - tol, inner.box.maxY <= outer.box.maxY + tol else {
                return false
            }
            return inner.samples.allSatisfy { isInsideLoop($0, loop: outer.segments) }
        }

        // For each shape: every shape that contains it.
        var containers: [[Int]] = Array(repeating: [], count: shapes.count)
        for i in shapes.indices {
            for j in shapes.indices where i != j && isInside(shapes[i], shapes[j]) {
                containers[i].append(j)
            }
        }

        // Nesting depth is the number of containers. The direct parent is the smallest one.
        var parent: [Int?] = Array(repeating: nil, count: shapes.count)
        for i in shapes.indices {
            parent[i] = containers[i].min { shapes[$0].area < shapes[$1].area }
        }

        var detectedIslands: [Int: [SC.Contour]] = [:]   // keyed by the pocket's original index
        var consumed = Set<Int>()                        // original indices folded in as islands

        for i in shapes.indices where containers[i].count % 2 == 1 {
            guard let p = parent[i] else {
                continue
            }
            detectedIslands[shapes[p].index, default: []].append(contours[shapes[i].index])
            consumed.insert(shapes[i].index)
        }

        var result: [SC.Contour] = []
        for (index, contour) in contours.enumerated() where !consumed.contains(index) {
            var pocket = contour
            if let found = detectedIslands[index] {
                pocket.islands.append(contentsOf: found)
            }
            result.append(pocket)
        }
        return result
    }

    // MARK: - Sampling

    /// Boundary points used for the containment test: segment starts plus a few interior
    /// points per segment, so an arc bulging across another contour can't hide between
    /// its endpoints.
    private func nestingSamples(of segments: [SC.Segment]) -> [CGPoint] {
        var points: [CGPoint] = []
        for segment in segments {
            points.append(contentsOf: sampledPoints(of: segment, steps: 4))
        }
        return points
    }

    /// A closed polygon approximating the contour, for its area.
    private func nestingPolygon(of segments: [SC.Segment]) -> [CGPoint] {
        var points: [CGPoint] = []
        for segment in segments {
            points.append(contentsOf: sampledPoints(of: segment, steps: 16))
        }
        return points
    }

    /// `steps` points along `segment`, starting at its start point (end point excluded:
    /// it is the next segment's start in a closed chain).
    private func sampledPoints(of segment: SC.Segment, steps: Int) -> [CGPoint] {
        switch segment {
            case .line(let start, let end):
                return (0..<steps).map { k in
                    let t = Double(k) / Double(steps)
                    return CGPoint(x: start.x + t * (end.x - start.x),
                                   y: start.y + t * (end.y - start.y))
                }

            case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                let sweep = SC.Segment.sweepAngle(start: startAngle, end: endAngle, isCCW: isCCW)
                let direction: Double = isCCW ? 1 : -1
                return (0..<steps).map { k in
                    let angle = startAngle + direction * sweep * Double(k) / Double(steps)
                    return CGPoint(x: center.x + radius * cos(angle),
                                   y: center.y + radius * sin(angle))
                }
        }
    }
}
