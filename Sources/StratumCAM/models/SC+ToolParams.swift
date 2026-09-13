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
        case threadMill
    }

    /// Describes the physical cutting tool itself -- the facts that live on the tool's
    /// label or datasheet and don't change from job to job (unlike `CuttingData`, which
    /// captures how aggressively *this* job cuts with it).
    public struct ToolParams: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var type: ToolType
        public var diameter: Double             // Tool diameter (mm/in)
        public var vAngle: Double?              // Included angle in degrees for V-bits (e.g., 60.0, 90.0)
        public var fluteLength: Double           // Total cutting edge length (allows deep Z adaptive passes)

        public init(id: UUID = UUID(),
                    name: String = "1/4\" Flat End Mill",
                    type: ToolType = .flatEndMill,
                    diameter: Double = 6.35,
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
