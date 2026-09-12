//
//  ToolType.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public enum ToolType: String, Sendable, Codable, Equatable {
        case flatEndMill
        case ballEndMill
        case vBit
        case drill
    }

    public struct ToolParams: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var type: ToolType
        public var diameter: Double             // Tool diameter (mm/in)
        public var stepdown: Double             // Max depth per Z-pass
        public var stepoverPercentage: Double   // 0.1 to 0.95 (10% to 95% of tool diameter)
        public var vAngle: Double?              // Included angle in degrees for V-bits (e.g., 60.0, 90.0)
        public var fluteLength: Double          // Total cutting edge length (allows deep Z adaptive passes)
        public var maxOptimalLoad: Double       // Maximum radial stepover allowance for adaptive motion (mm)
        public var spindleSpeed: Double?        // Optional tool-specific spindle speed (RPM)

        public init(id: UUID = UUID(),
                    name: String = "1/4\" Flat End Mill",
                    type: ToolType = .flatEndMill,
                    diameter: Double = 6.35,
                    stepdown: Double = 1.5,
                    stepoverPercentage: Double = 0.4,
                    vAngle: Double? = nil,
                    fluteLength: Double = 12,
                    maxOptimalLoad: Double = 0.0,
                    spindleSpeed: Double? = nil) {

            self.id = id
            self.name = name
            self.type = type
            self.diameter = diameter
            self.stepdown = stepdown
            self.stepoverPercentage = stepoverPercentage
            self.vAngle = vAngle
            self.fluteLength = fluteLength
            self.maxOptimalLoad = maxOptimalLoad
            self.spindleSpeed = spindleSpeed
        }
    }
}
