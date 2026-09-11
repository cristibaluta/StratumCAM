//
//  AdaptiveType.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public enum AdaptiveType: String, Sendable, Codable, Equatable {
        case clearing2D           // Adaptive pocket / dynamic roughing
        case adaptiveContour      // High-speed profile adaptive clearing
    }
}
