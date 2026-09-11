//
//  EntryStrategy.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public enum EntryStrategy: Sendable, Equatable {
        /// Direct vertical plunge into pre-drilled holes or soft material.
        case plunge

        /// Zig-zag back and forth at a shallow angle to reach pass depth.
        case ramp(angleDegrees: Double)

        /// Spiral down into the material in a circular motion (ideal for pockets/adaptive).
        case helix(radius: Double, rampAngleDegrees: Double)
    }
}
