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

        public init(cutting: CuttingData = CuttingData(),
                    safeZ: Double = 5.0,
                    retractZ: Double = 1.0,
                    targetDepth: Double = 3.0,
                    retractPolicy: RetractPolicy = .safeZ) {

            self.cutting = cutting
            self.safeZ = safeZ
            self.retractZ = retractZ
            self.targetDepth = targetDepth
            self.retractPolicy = retractPolicy
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
