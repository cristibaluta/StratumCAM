//
//  Side.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public enum CutSide: String, Sendable, Codable, Equatable {
        case inside
        case outside
        case onContour
    }
}
