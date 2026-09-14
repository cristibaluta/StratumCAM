//
//  OffsetTools.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 14.09.2026.
//

import Foundation

struct OffsetTools {
    /// Resolves `.inside` / `.outside` into a signed offset distance (positive = left of
    /// travel direction), based on the contour's winding direction.
    static func offsetDistance(for side: SC.CutSide, toolRadius: Double, segments: [SC.Segment]) -> Double {
        switch side {
            case .onContour:
                return 0
            case .outside:
                return isCCWWinding(segments) ? -toolRadius : toolRadius
            case .inside:
                return isCCWWinding(segments) ? toolRadius : -toolRadius
        }
    }

    // MARK: - Winding

    /// Approximates the signed area of a closed contour (sampling arcs) to determine
    /// winding direction. Positive area = counter-clockwise.
    static func isCCWWinding(_ segments: [SC.Segment]) -> Bool {
        var points: [CGPoint] = []
        for segment in segments {
            switch segment {
                case .line(let start, _):
                    points.append(start)

                case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                    let sweep = isCCW ? (endAngle - startAngle) : (startAngle - endAngle)
                    let steps = max(1, Int(abs(sweep) / (.pi / 18))) // ~10 deg per sample
                    for s in 0..<steps {
                        let t = Double(s) / Double(steps)
                        let angle = startAngle + (isCCW ? sweep : -sweep) * t
                        points.append(
                            CGPoint(x: center.x + radius * cos(angle),
                                    y: center.y + radius * sin(angle))
                        )
                    }
            }
        }
        guard points.count >= 3 else {
            return true
        }

        var area = 0.0
        for i in 0..<points.count {
            let p1 = points[i]
            let p2 = points[(i + 1) % points.count]
            area += p1.x * p2.y - p2.x * p1.y
        }
        return area > 0
    }
}
