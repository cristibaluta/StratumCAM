//
//  LeadInOut.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    /// How the tool eases onto and off of a profile cut, instead of engaging or disengaging the wall directly.
    public struct LeadInOut: Sendable, Equatable {

        public enum Style: Sendable, Equatable {
            case linear(length: Double)
            /// A tangent arc. The magnitude of `sweepAngleDegrees` is the arc's sweep; its sign picks the
            /// side the arc swings to: positive (default) puts it in the free space beside the wall,
            /// negative mirrors it to the other side of the contour.
            case arc(radius: Double, sweepAngleDegrees: Double)
        }

        public var style: Style
        public var feedRate: Double

        public init(style: Style, feedRate: Double) {
            self.style = style
            self.feedRate = feedRate
        }
    }
}
