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
    /// `MachiningOperation`, it clears the whole `Stock` footprint once -- so it
    /// can't go through `generateToolpaths(from contours:tool:settings:operation:)`'s
    /// per-contour dispatch the way `.pocket`/`.contour`/etc. do. This mirrors
    /// `DrillingOperation`'s existing solution to the same kind of signature
    /// mismatch (drilling's per-hole batch, here facing's per-stock one): a small,
    /// dedicated struct bundling the stock with its own tool/settings, consumed by
    /// a matching `generateToolpaths(from operations: [FacingOperation])` overload
    /// rather than forcing facing through the per-contour path just because that's
    /// what's already wired up.
    public struct FacingOperation: Sendable {
        public var stock: Stock
        public var tool: ToolParams
        public var settings: MachineSettings
        public var stepover: Double
        public var direction: CutDirection
        public var extensionLength: Double

        public init(stock: Stock,
                    tool: ToolParams,
                    settings: MachineSettings,
                    stepover: Double,
                    direction: CutDirection = .climb,
                    extensionLength: Double = 0) {
            self.stock = stock
            self.tool = tool
            self.settings = settings
            self.stepover = stepover
            self.direction = direction
            self.extensionLength = extensionLength
        }
    }
}
