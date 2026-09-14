//
//  FacingOperation.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation

extension SC {

    /// Describes one facing operation against a stock's top-face footprint.
    ///
    /// `.facing` has no selected contour to iterate -- unlike every other
    /// `MachiningOperation`, it clears the whole `Stock` footprint once
    public struct FacingOperation: Sendable {
        public var stock: Stock
        public var tool: ToolParams
        public var settings: MachineSettings
        public var direction: CutDirection
        public var extensionLength: Double

        /// No `stepover` here on purpose: facing has no wall to protect the way a
        /// pocket does, so there's no finish/chip-load tradeoff for a caller to tune --
        /// the engine derives row spacing directly from `tool.diameter` (see
        /// `SCEngine.facingStepover(for:)`) so the full footprint is always covered
        /// with no unmilled strip between rows, regardless of which tool is passed in.
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
