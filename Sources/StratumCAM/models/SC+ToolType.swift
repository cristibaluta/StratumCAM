//
//  ToolType.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 24.10.2026.
//

import Foundation

extension SC {

    public enum ToolType: String, Sendable, Codable, Equatable {
        case flatEndMill
        case ballEndMill
        case vBit
        case drill
        /// Diameter of the tool refers at the tip with the knives. The axe itself is a bit smaller to allow th eknives to cut the thread
        case threadMill
    }
}
