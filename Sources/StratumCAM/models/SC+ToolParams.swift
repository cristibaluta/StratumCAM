//
//  ToolParams.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

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

        // MARK: Machine / post-processor data (used by SCMakeraGCodeEngine)

        /// Tool slot number (`T<n>M6`).
        public var number: Int
        /// Read by the Carvera post: "TLO:A" (auto), "TLO:M" (manual), "TLO:-14" (fixed offset),
        /// or free-form `M6` parameters when `toolCommentAsChangeParameters` is on.
        public var comment: String
        /// Spindle rotation: `true` = M3 (clockwise), `false` = M4.
        public var clockwise: Bool
        /// Shank diameter, used to pick the collet on community firmware.
        public var shaftDiameter: Double?
        /// Tool must be changed by hand (pause + collet release/close + probe).
        public var manualToolChange: Bool

        public init(id: UUID = UUID(),
                    name: String = "1/8\" Flat End Mill",
                    type: ToolType = .flatEndMill,
                    diameter: Double = 3.175,
                    vAngle: Double? = nil,
                    fluteLength: Double = 12,
                    number: Int = 1,
                    comment: String = "",
                    clockwise: Bool = true,
                    shaftDiameter: Double? = nil,
                    manualToolChange: Bool = false) {

            self.id = id
            self.name = name
            self.type = type
            self.diameter = diameter
            self.vAngle = vAngle
            self.fluteLength = fluteLength
            self.number = number
            self.comment = comment
            self.clockwise = clockwise
            self.shaftDiameter = shaftDiameter
            self.manualToolChange = manualToolChange
        }
    }
}
