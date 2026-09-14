//
//  Math+Extensions.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 14.09.2026.
//


extension Double {
    var degreesToRadians: Double {
        return self * .pi / 180
    }
}

extension Int {
    var degreesToRadians: Double {
        return Double(self) * .pi / 180
    }
}