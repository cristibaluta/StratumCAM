//
//  CuttingData.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 12.09.2026.
//

import Foundation

extension SC {

    /// Describes how a cut is actually performed with a given tool for a given job --
    /// as opposed to `ToolParams`, which describes the physical tool itself. These values
    /// change with material, operation, and aggressiveness even when the same physical
    /// tool is reused, so they're kept separate from the tool's identity.
    public struct CuttingData: Sendable, Equatable {

        /// Target spindle speed (RPM).
        public var spindleSpeed: Double

        /// XY cutting feed rate (mm/min).
        public var feedRate: Double

        /// Z entry feed rate (mm/min).
        public var plungeRate: Double

        /// Max depth per Z-pass (mm).
        public var stepdown: Double

        /// 0.1 to 0.95 (10% to 95% of tool diameter). Stored as a percentage rather than
        /// an absolute distance so it survives a tool-diameter change without silently
        /// becoming too aggressive or too conservative -- resolve to mm via
        /// `stepoverPercentage * tool.diameter` at the point of use.
        public var stepoverPercentage: Double

        /// Maximum radial stepover allowance for adaptive motion (mm). Unlike
        /// `stepoverPercentage`, this is a physical chip-load/engagement-angle limit that
        /// doesn't scale linearly with tool diameter, so it's stored as an absolute value.
        public var maxOptimalLoad: Double

        public init(spindleSpeed: Double = 12000.0,
                    feedRate: Double = 1200.0,
                    plungeRate: Double = 300.0,
                    stepdown: Double = 1.5,
                    stepoverPercentage: Double = 0.4,
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
