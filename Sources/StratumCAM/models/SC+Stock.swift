//
//  Stock.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import simd

extension SC {

    public struct Stock: Sendable, Equatable {
        /// Size on X axis
        public var width: Double
        /// Size on Y axis
        public var height: Double
        /// Size on Z axis
        public var thickness: Double
        // Work coordinate offset
        public var origin: SIMD3<Double>

        public init(width: Double, height: Double, thickness: Double, origin: SIMD3<Double> = .zero) {
            self.width = width
            self.height = height
            self.thickness = thickness
            self.origin = origin
        }
    }
}
