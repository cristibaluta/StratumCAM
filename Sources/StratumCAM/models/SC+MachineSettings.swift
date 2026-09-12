//
//  MachineSettings.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public struct MachineSettings: Sendable, Equatable {

        public var feedRate: Double         // XY cutting feed rate (mm/min)
        public var plungeRate: Double       // Z plunge feed rate (mm/min)
        public var spindleSpeed: Double     // RPM
        public var safeZ: Double            // Rapid clearance plane above stock
        public var retractZ: Double         // Short lift clearance between close cuts
        public var targetDepth: Double      // Total depth of cut (positive depth into stock)
        public var dwell: Double?           // Optional drilling dwell in seconds

        public init(feedRate: Double = 1200.0,
                    plungeRate: Double = 300.0,
                    spindleSpeed: Double = 12000.0,
                    safeZ: Double = 5.0,
                    retractZ: Double = 1.0,
                    targetDepth: Double = 3.0,
                    dwell: Double? = nil) {

            self.feedRate = feedRate
            self.plungeRate = plungeRate
            self.spindleSpeed = spindleSpeed
            self.safeZ = safeZ
            self.retractZ = retractZ
            self.targetDepth = targetDepth
            self.dwell = dwell
        }
    }
}
