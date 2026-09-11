//
//  SC 2.swift
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
