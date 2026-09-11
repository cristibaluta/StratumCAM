//
//  Segment.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public enum Segment: Sendable, Equatable {
        
        case line(start: CGPoint, end: CGPoint)
        case arc(center: CGPoint, radius: Double, startAngle: Double, endAngle: Double, isCCW: Bool)

        public var startPoint: CGPoint {
            switch self {
                case .line(let start, _): return start
                case .arc(let center, let radius, let startAngle, _, _):
                    return CGPoint(x: center.x + radius * cos(startAngle),
                                   y: center.y + radius * sin(startAngle))
            }
        }

        public var endPoint: CGPoint {
            switch self {
                case .line(_, let end): return end
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
