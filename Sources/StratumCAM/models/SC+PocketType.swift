//
//  PocketType.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public enum PocketType: String, Sendable, Codable, Equatable {
        case offsetPattern               // Concentric inner-to-outer shapes
        case raster                      // Parallel scanlines
    }
}
