//
//  CutDirection.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public enum CutDirection: String, Sendable, Codable, Equatable {
        case climb           // Standard for CNC mills
        case conventional
    }
}
