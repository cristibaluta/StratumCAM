//
//  Contour.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public struct Contour: Sendable {

        public struct Chained: Sendable {
            public var geometry: SC.Geometry
            public var reversed: Bool

            // NOTE: The inits are needed because the app using the lib is not able to init otherwise
            public init(geometry: SC.Geometry, reversed: Bool) {
                self.geometry = geometry
                self.reversed = reversed
            }
        }

        // TODO: proposal: this needs to be renamed to segments of type [GeometriesChain]
        public var entities: [Chained]
        public var isClosed: Bool

        /// Islands inside this contour
        public var islands: [Contour]

        public init(entities: [Chained], isClosed: Bool, islands: [Contour] = []) {
            self.entities = entities
            self.isClosed = isClosed
            self.islands = islands
        }
    }
}

extension SC.Contour {
    /// Extracts a single drill point (XY) from a contour, if the contour represents
    /// one. Two shapes are recognized as "drill here" markers:
    /// - A single `.point` entity -- the explicit case.
    /// - A single closed `.circle` entity -- common in DXF for marking hole centers,
    ///   since many CAD tools don't have a dedicated point primitive for this. `isClosed`
    ///   must be `true` so a circle used for other strategies (e.g. engraving a ring)
    ///   isn't silently reinterpreted as a hole.
    ///
    /// Any other contour shape (lines, arcs, polylines, multiple entities, an open
    /// circle) returns `nil` here -- it isn't an explicit point/circle marker. `.drilling`
    /// doesn't stop at `nil`, though: it falls back to `closedShapeCenter` below, so a
    /// closed contour of any shape is still drillable at its center; this property alone
    /// stays narrow because `.boring`/`.counterbore`/`.threadMilling` reuse it too, and a
    /// bounding-box center isn't the right fallback for cutting to an exact diameter.
    var drillPoint: CGPoint? {
        guard self.entities.count == 1 else {
            return nil
        }
        switch self.entities[0].geometry {
            case let .point(at):
                return at.cgPoint

            case let .circle(center, _):
                return isClosed ? center.cgPoint : nil

            default:
                return nil
        }
    }

    /// The axis-aligned bounding-box center of a closed contour's geometry -- "the
    /// middle of whatever shape this is," regardless of what that shape is. `.drilling`
    /// falls back to this (see `SCEngine.buildDrillingToolpath`) when a contour isn't a
    /// single point or closed circle, so any closed boundary -- a square, an odd
    /// polygon, a rounded rectangle -- is still drillable at its center. That's useful
    /// for e.g. pre-drilling a stress-relief hole in the middle of a pocket boundary
    /// before running an adaptive-clearing pass over it, without having to separately
    /// mark a point or circle at the same spot.
    ///
    /// This is a bounding-box center, not a true polygon centroid: exact for a circle or
    /// anything symmetric about its bounding box (square, rectangle, rounded rectangle),
    /// only an approximation for an irregular or concave shape, where it can land
    /// outside the boundary entirely (e.g. an L- or C-shaped pocket). That's an
    /// acceptable trade for a relief pre-drill; it isn't a substitute for a real
    /// centroid if a caller ever needs the point guaranteed inside the boundary.
    ///
    /// `nil` for an open contour (no well-defined "middle") or one with no measurable
    /// geometry.
    var closedShapeCenter: CGPoint? {
        guard isClosed else {
            return nil
        }

        let box = linearizedSegments.boundingBox
        guard box.minX.isFinite, box.maxX.isFinite, box.minY.isFinite, box.maxY.isFinite else {
            return nil
        }

        return CGPoint(x: (box.minX + box.maxX) / 2, y: (box.minY + box.maxY) / 2)
    }

    /// How close and how far the boundary of this closed contour is from `point`: the radii
    /// of the largest circle around `point` that fits inside the shape (`nearest`) and of
    /// the smallest one that contains it (`farthest`). Thread milling reads the free space
    /// of a hole (`nearest`) or the size of a stud (`farthest`) from these, without needing
    /// the shape to be a circle.
    ///
    /// Arcs are measured as short chords (2 degrees each), which is off by under 2 microns even
    /// on a 10 mm radius hole. `nil` for an open contour or one with no geometry.
    func boundaryDistances(from point: CGPoint) -> (nearest: Double, farthest: Double)? {
        guard isClosed else {
            return nil
        }

        var nearest = Double.infinity
        var farthest = 0.0

        for segment in linearizedSegments {
            let points: [CGPoint]
            switch segment {
                case .line(let start, let end):
                    points = [start, end]

                case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                    var sweep = (isCCW ? endAngle - startAngle : startAngle - endAngle)
                        .truncatingRemainder(dividingBy: 2 * .pi)
                    if sweep < 1e-9 {
                        sweep += 2 * .pi
                    }
                    let direction: Double = isCCW ? 1 : -1
                    let steps = max(2, Int((sweep / (.pi / 90)).rounded(.up)))
                    points = (0...steps).map { i in
                        let angle = startAngle + direction * sweep * Double(i) / Double(steps)
                        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                    }
            }

            var previous: CGPoint?
            for p in points {
                farthest = max(farthest, hypot(p.x - point.x, p.y - point.y))
                if let a = previous {
                    nearest = min(nearest, Self.distance(from: point, toSegment: a, p))
                }
                previous = p
            }
        }

        guard nearest.isFinite, farthest > 0 else {
            return nil
        }
        return (nearest, farthest)
    }

    private static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-18 else {
            return hypot(point.x - a.x, point.y - a.y)
        }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}
