//
//  HoldingTab.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public struct HoldingTab: Sendable, Equatable, Hashable, Identifiable, Codable {
        public var id: UUID
        /// 0.0 to 1.0 parametric distance along contour
        public var positionRatio: Double
        /// Length along toolpath (mm)
        public var width: Double
        /// Remaining stock height for tab (mm)
        public var height: Double

        public init(id: UUID = UUID(), positionRatio: Double, width: Double = 6.0, height: Double = 1.5) {
            self.id = id
            self.positionRatio = positionRatio
            self.width = width
            self.height = height
        }

        /// The `id` only identifies the tab in an editor, so it isn't saved: a decoded tab gets a new one.
        private enum CodingKeys: String, CodingKey {
            case positionRatio, width, height
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = UUID()
            self.positionRatio = try container.decode(Double.self, forKey: .positionRatio)
            self.width = try container.decode(Double.self, forKey: .width)
            self.height = try container.decode(Double.self, forKey: .height)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(positionRatio, forKey: .positionRatio)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
        }
    }
}
