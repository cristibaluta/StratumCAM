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
        /// Height above the top of the stock (Z0, mm, positive) where the tool slows down from
        /// rapid to the entry feed: it rapids from `safeZ` down to here, then feeds in at the
        /// plunge rate and the entry strategy (plunge, ramp, helix) is applied from there.
        /// `nil` (the default) keeps the old behaviour, where the entry feed starts at `safeZ`.
        /// Ignored when it is not below `safeZ`.
        public var entryZ: Double?
        /// Height above the top of the stock (Z0, mm, positive) where the ramp or helix of the
        /// FIRST pass starts, so the tool begins its angled descent in the air, above the
        /// material, instead of at the stock surface. The slope is the entry's own angle, so a
        /// higher start just makes the ramp longer.
        ///
        /// Only the first pass starts there: every following pass starts its ramp or helix from
        /// the Z of the pass before it, which is already cut. `nil` (the default) starts the
        /// first pass at Z0. Plunge entries ignore it. Values above `safeZ` are limited to
        /// `safeZ`.
        ///
        /// Not the same as `entryZ`, which is where the tool slows from rapid to the plunge feed
        /// on the way down to the entry; the two combine: the tool rapids to `entryZ`, feeds
        /// down to `rampStartZ` when that is lower, and starts the ramp or helix from there.
        public var rampStartZ: Double?
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
                    entryZ: Double? = nil,
                    targetDepth: Double = 3.0,
                    retractPolicy: RetractPolicy = .safeZ,
                    allowance: Double = 0.0,
                    finishingPass: Bool = false,
                    rampStartZ: Double? = nil) {

            self.cutting = cutting
            self.safeZ = safeZ
            self.retractZ = retractZ
            self.entryZ = entryZ
            self.targetDepth = targetDepth
            self.retractPolicy = retractPolicy
            self.allowance = allowance
            self.finishingPass = finishingPass
            self.rampStartZ = rampStartZ
        }

        /// Z where the first pass's ramp or helix starts: the stock top (Z0) by default, or
        /// `rampStartZ` above it, never higher than `safeZ`. Later passes start from the
        /// previous pass's Z instead.
        public var firstPassStartZ: Double {
            guard let rampStartZ, rampStartZ > 0 else {
                return 0
            }
            return max(0, min(rampStartZ, safeZ))
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
