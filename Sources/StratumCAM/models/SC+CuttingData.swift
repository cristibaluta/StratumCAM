//
//  CuttingData.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 12.09.2026.
//

import Foundation

extension SC {

    public struct CuttingData: Sendable, Equatable {

        /// Target spindle speed (RPM).
        public var spindleSpeed: Double

        /// XY cutting feed rate (mm/min).
        public var feedRate: Double

        /// Z entry feed rate (mm/min).
        public var plungeRate: Double

        /// Max depth per Z-pass (mm).
        public var stepdown: Double

        /// Radial stepover as a fraction of the tool *diameter*: 0.1 to 0.95 (10% to 95%),
        /// default 0.25 (25%). Stored as a percentage rather than an absolute distance so it
        /// survives a tool-diameter change
        public var stepoverPercentage: Double

        /// Maximum radial stepover allowance for adaptive motion (mm). Unlike
        /// `stepoverPercentage`, this is a physical chip-load/engagement-angle limit that
        /// doesn't scale linearly with tool diameter, so it's stored as an absolute value.
        public var maxOptimalLoad: Double

        public init(spindleSpeed: Double = 12000.0,
                    feedRate: Double = 1200.0,
                    plungeRate: Double = 300.0,
                    stepdown: Double = 0.1,
                    stepoverPercentage: Double = 0.25,
                    maxOptimalLoad: Double = 0.0) {

            self.spindleSpeed = spindleSpeed
            self.feedRate = feedRate
            self.plungeRate = plungeRate
            self.stepdown = stepdown
            self.stepoverPercentage = stepoverPercentage
            self.maxOptimalLoad = maxOptimalLoad
        }
    }
}
