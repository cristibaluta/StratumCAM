//
//  HoldingTab.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public struct HoldingTab: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var positionRatio: Double    // 0.0 to 1.0 parametric distance along contour
        public var width: Double            // Length along toolpath (mm)
        public var height: Double           // Remaining stock height for tab (mm)

        public init(id: UUID = UUID(), positionRatio: Double, width: Double = 6.0, height: Double = 1.5) {
            self.id = id
            self.positionRatio = positionRatio
            self.width = width
            self.height = height
        }
    }
}
