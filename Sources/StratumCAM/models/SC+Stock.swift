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
        public var width: Double            // X size
        public var height: Double           // Y size
        public var thickness: Double        // Z size
        public var origin: SIMD3<Double>    // Work coordinate offset (WCS G54 origin)

        public init(width: Double, height: Double, thickness: Double, origin: SIMD3<Double> = .zero) {
            self.width = width
            self.height = height
            self.thickness = thickness
            self.origin = origin
        }
    }
}
