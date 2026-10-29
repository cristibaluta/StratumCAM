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
        /// Moves the move along a closed contour, as a fraction (0...1) of its length.
        /// For a lead-in it is where the cut starts, counted from the contour's own start point.
        /// For a lead-out it is how far the cut carries on past where it would end before leaving.
        /// Open contours ignore it.
        public var positionRatio: Double
        /// For a linear lead: the angle between the run and the contour, in degrees. 0 is in line
        /// with the contour; positive leans towards the free side, negative towards the material.
        /// Arcs ignore it (their sweep is the angle).
        public var angleDegrees: Double

        public init(style: Style, feedRate: Double, positionRatio: Double = 0, angleDegrees: Double = 0) {
            self.angleDegrees = angleDegrees
            self.style = style
            self.feedRate = feedRate
            self.positionRatio = positionRatio
        }
    }
}
