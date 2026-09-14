//
//  ToolParams.swift
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
        /// Diameter of the tool refers at the tip with the knives. The axe itself is a bit smaller to allow th eknives to cut the thread
        case threadMill
    }

    /// Describes the physical cutting tool itself
    public struct ToolParams: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var type: ToolType
        // Cutting diameter (mm/in)
        public var diameter: Double
        /// Included angle in degrees for V-bits (e.g., 60.0, 90.0)
        public var vAngle: Double?
        /// Total cutting edge length
        public var fluteLength: Double

        public init(id: UUID = UUID(),
                    name: String = "1/8\" Flat End Mill",
                    type: ToolType = .flatEndMill,
                    diameter: Double = 3.175,
                    vAngle: Double? = nil,
                    fluteLength: Double = 12) {

            self.id = id
            self.name = name
            self.type = type
            self.diameter = diameter
            self.vAngle = vAngle
            self.fluteLength = fluteLength
        }
    }
}
