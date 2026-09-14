//
//  FacingOperation.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation

extension SC {

    /// Describes one facing operation against a stock's top-face footprint.
    public struct FacingOperation: Sendable {
        public var stock: Stock
        public var tool: ToolParams
        public var settings: MachineSettings
        public var direction: CutDirection
        public var extensionLength: Double

        public init(stock: Stock,
                    tool: ToolParams,
                    settings: MachineSettings,
                    direction: CutDirection = .climb,
                    extensionLength: Double = 0) {
            self.stock = stock
            self.tool = tool
            self.settings = settings
            self.direction = direction
            self.extensionLength = extensionLength
        }
    }
}
