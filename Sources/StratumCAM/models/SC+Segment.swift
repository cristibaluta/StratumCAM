//
//  Segment.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public enum Segment: Sendable, Equatable {
        
        case line(start: CGPoint,
                  end: CGPoint)

        /// angle is in radians
        case arc(center: CGPoint,
                 radius: Double,
                 startAngle: Double,
                 endAngle: Double,
                 isCCW: Bool)

        public var startPoint: CGPoint {
            switch self {
                case .line(let start, _):
                    return start
                case .arc(let center, let radius, let startAngle, _, _):
                    return CGPoint(x: center.x + radius * cos(startAngle),
                                   y: center.y + radius * sin(startAngle))
            }
        }

        public var endPoint: CGPoint {
            switch self {
                case .line(_, let end):
                    return end
                case .arc(let center, let radius, _, let endAngle, _):
                    return CGPoint(x: center.x + radius * cos(endAngle),
                                   y: center.y + radius * sin(endAngle))
            }
        }
    }
}

extension SC.Segment {

    /// Offsets this segment perpendicular to its direction of travel.
    /// `distance > 0` shifts left of travel direction, `distance < 0` shifts right.
    /// Returns `nil` if the offset collapses the segment (e.g. the tool radius
    /// is larger than an arc it would have to shrink).
    func offset(by distance: Double) -> SC.Segment? {

        guard abs(distance) > 1e-9 else {
            return self
        }

        switch self {
            case .line(let start, let end):
                let dx = end.x - start.x
                let dy = end.y - start.y
                let length = hypot(dx, dy)
                guard length > 1e-9 else {
                    return nil
                }
                // Left-hand normal of the direction of travel
                let nx = -dy / length
                let ny = dx / length

                return .line(
                    start: CGPoint(x: start.x + nx * distance, y: start.y + ny * distance),
                    end: CGPoint(x: end.x + nx * distance, y: end.y + ny * distance)
                )

            case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                // Offsetting left shrinks a CCW arc and grows a CW arc (and vice versa) --
                // a CCW arc curves toward its center on the left of travel direction.
                let newRadius = isCCW ? radius - distance : radius + distance
                guard newRadius > 1e-6 else {
                    return nil // tool doesn't fit inside this arc
                }

                return .arc(center: center, radius: newRadius, startAngle: startAngle, endAngle: endAngle, isCCW: isCCW)
        }
    }

    /// Rebuilds this segment with a new start point (used when trimming a concave corner).
    func withStart(_ point: CGPoint) -> SC.Segment {
        switch self {
            case .line(_, let end):
                return .line(start: point, end: end)

            case .arc(let center, let radius, _, let endAngle, let isCCW):
                let angle = atan2(point.y - center.y, point.x - center.x)

                return .arc(center: center, radius: radius, startAngle: angle, endAngle: endAngle, isCCW: isCCW)
        }
    }

    /// Rebuilds this segment with a new end point (used when trimming a concave corner).
    func withEnd(_ point: CGPoint) -> SC.Segment {
        switch self {
            case .line(let start, _):
                return .line(start: start, end: point)

            case .arc(let center, let radius, let startAngle, _, let isCCW):
                let angle = atan2(point.y - center.y, point.x - center.x)

                return .arc(center: center, radius: radius, startAngle: startAngle, endAngle: angle, isCCW: isCCW)
        }
    }

    /// The same physical geometry, travelled in the opposite direction -- used to flip a
    /// whole contour chain between climb and conventional milling.
    var reversed: SC.Segment {
        switch self {
            case .line(let start, let end):
                return .line(start: end, end: start)

            case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                return .arc(center: center, radius: radius, startAngle: endAngle, endAngle: startAngle, isCCW: !isCCW)
        }
    }
}

extension [SC.Segment] {

    /// The true bounding box of a segment chain, sampling each arc's angular sweep for
    /// its axis-aligned extremes (0/90/180/270 degrees) rather than just its two
    /// endpoints -- the top of a semicircle, for example, doesn't lie on either endpoint.
    /// A safe superset is enough for scanline generation (an over-wide box just probes a
    /// few rows that come back empty and get skipped), but not an under-wide one.
    var boundingBox: (minX: Double, maxX: Double, minY: Double, maxY: Double) {

        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity

        func include(_ point: CGPoint) {
            minX = Swift.min(minX, point.x)
            maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y)
            maxY = Swift.max(maxY, point.y)
        }

        for segment in self {
            include(segment.startPoint)
            include(segment.endPoint)

            if case .arc(let center, let radius, let startAngle, let endAngle, let isCCW) = segment {
                for extremeAngle in stride(from: 0.0, to: 2 * .pi, by: .pi / 2) {
                    if EngineTools.angleWithinSweep(extremeAngle, start: startAngle, end: endAngle, isCCW: isCCW) {
                        include(CGPoint(x: center.x + radius * cos(extremeAngle),
                                        y: center.y + radius * sin(extremeAngle)))
                    }
                }
            }
        }

        return (minX, maxX, minY, maxY)
    }

    /// Total arc length of a segment chain -- shared by `trochoidalSegments`'s loop
    /// spacing and `point(alongPath:distance:totalLength:)` below, which places a loop
    /// center a given distance along the chain.
    var pathLength: Double {
        self.reduce(0.0) { $0 + $1.pathLength }
    }
}

extension SC.Segment {

    var pathLength: Double {
        switch self {
            case .line(let start, let end):
                // straight-line distance between two 2D points
                return hypot(end.x - start.x, end.y - start.y)

            case .arc(_, let radius, let startAngle, let endAngle, _):
                // Calculates the arc length
                let sweep = endAngle - startAngle
                return radius * abs(sweep)
        }
    }
}
