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
        /// Optional drilling dwell in seconds
        public var dwell: Double?

        public init(cutting: CuttingData = CuttingData(),
                    safeZ: Double = 5.0,
                    retractZ: Double = 1.0,
                    targetDepth: Double = 3.0,
                    dwell: Double? = nil) {

            self.cutting = cutting
            self.safeZ = safeZ
            self.retractZ = retractZ
            self.targetDepth = targetDepth
            self.dwell = dwell
        }
    }
}
