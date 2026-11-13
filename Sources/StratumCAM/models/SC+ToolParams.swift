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
        // Cutting diameter (mm)
        public var diameter: Double
        /// Included angle in degrees for V-bits (e.g., 60.0, 90.0)
        public var vAngle: Double?
        /// Width of the flat at the very tip of a V-bit (mm), 0 for a sharp point. `diameter` is
        /// the cutting diameter at the TOP of the angled flank, so the flank's height follows
        /// from `diameter`, `tipWidth` and `vAngle` (see `flankHeight`).
        public var tipWidth: Double
        /// Total cutting edge length
        ///  For v bits is the angled cutting part
        public var fluteLength: Double

        // MARK: Machine / post-processor data (used by SCMakeraGCodeEngine)

        /// Tool slot number (`T<n>M6`).
        public var number: Int
        /// Read by the Carvera post: "TLO:A" (auto), "TLO:M" (manual), "TLO:-14" (fixed offset),
        /// or free-form `M6` parameters when `toolCommentAsChangeParameters` is on.
        public var comment: String
        /// Spindle rotation: `true` = M3 (clockwise), `false` = M4.
        public var clockwise: Bool
        /// Shank diameter, used to pick the collet
        public var shaftDiameter: Double?
        /// Tool must be changed by hand (pause + collet release/close + probe).
        public var manualToolChange: Bool

        public init(id: UUID = UUID(),
                    name: String = "1/8\" Flat End Mill",
                    type: ToolType = .flatEndMill,
                    diameter: Double = 3.175,
                    vAngle: Double? = nil,
                    tipWidth: Double = 0,
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
            self.tipWidth = tipWidth
            self.fluteLength = fluteLength
            self.number = number
            self.comment = comment
            self.clockwise = clockwise
            self.shaftDiameter = shaftDiameter
            self.manualToolChange = manualToolChange
        }
    }
}

extension SC.ToolParams {

    /// Height of a V-bit's angled (cutting) flank, measured along the tool axis from the tip
    /// up to where the flank reaches the full `diameter`:
    /// `(diameter - tipWidth) / 2 / tan(vAngle / 2)`.
    ///
    /// `nil` when the tool isn't a V-bit or has no usable `vAngle`. `0` when the tip flat is as
    /// wide as the tool (nothing left to cut with).
    public var flankHeight: Double? {
        guard type == .vBit, let vAngle, vAngle > 0, vAngle < 180 else {
            return nil
        }
        let radial = (diameter - tipWidth) / 2
        guard radial > 0 else {
            return 0
        }
        return radial / tan((vAngle / 2).degreesToRadians)
    }
}
