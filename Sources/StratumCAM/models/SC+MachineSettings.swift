//
//  MachineSettings.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public struct MachineSettings: Sendable, Equatable {

        // Spindle/feed/stepdown/stepover cutting conditions
        public var cutting: CuttingData
        /// Rapid clearance plane above stock
        public var safeZ: Double
        /// Short lift clearance between close cuts
        public var retractZ: Double
        /// Total depth of cut (positive depth into stock)
        public var targetDepth: Double
        /// What the tool does between Z layers of a multi-pass operation.
        public var retractPolicy: RetractPolicy
        /// Stock to leave (mm): how much material the roughing passes leave standing on the
        /// finished walls, and, for a pocket, on the floor. 0 (the default) cuts straight to the
        /// finished size. Read by the operations whose `requirements.usesAllowance` is true
        /// (`.pocket` and `.contour` cut on a side); every other operation ignores it.
        ///
        /// For a pocket the floor is left by the same amount, so the roughing stops
        /// `allowance` short of `targetDepth`. A contour cuts all the way through, so only
        /// its wall is left.
        public var allowance: Double
        /// Cut the stock `allowance` left behind with a finishing pass, so the walls (and a
        /// pocket's floor) end at their true size. Does nothing when `allowance` is 0.
        ///
        /// The finishing passes are appended to the same `OutputToolpath`, after the roughing
        /// ones: a pocket gets a floor pass (one lap of the roughing pattern at full depth)
        /// and then a pass along its walls and around its islands; a contour is cut a second
        /// time at its true size, with the same entry, lead-in/out and holding tabs. They use
        /// the same stepdown as the roughing.
        public var finishingPass: Bool

        public init(cutting: CuttingData = CuttingData(),
                    safeZ: Double = 5.0,
                    retractZ: Double = 1.0,
                    targetDepth: Double = 3.0,
                    retractPolicy: RetractPolicy = .safeZ,
                    allowance: Double = 0.0,
                    finishingPass: Bool = false) {

            self.cutting = cutting
            self.safeZ = safeZ
            self.retractZ = retractZ
            self.targetDepth = targetDepth
            self.retractPolicy = retractPolicy
            self.allowance = allowance
            self.finishingPass = finishingPass
        }
    }

    /// What the tool does after finishing a Z layer, before starting the next one.
    ///
    /// Only applied when the move to the next layer's entry point is known to stay inside
    /// the cleared pocket (no islands, straight link inside the tool-centre region).
    /// Otherwise the engine falls back to `.safeZ`. The last layer always retracts to safe Z.
    public enum RetractPolicy: Sendable, Equatable {
        /// Full retract to `safeZ` after every layer (the default).
        case safeZ
        /// Lift only `MachineSettings.retractZ` above the layer just cut (never above `safeZ`),
        /// travel there, then go down into the next layer.
        case clearance
        /// No lift: travel to the next layer's entry point at the depth just cut.
        case none
    }
}
