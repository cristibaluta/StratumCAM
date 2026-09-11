//
//  DrillingOperation.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    /// Describes one drilling operation in a batch of holes.
    ///
    /// Keeping the tool and machine settings with each contour allows a single
    /// `generateToolpaths` call to contain holes using different drill tools and
    /// different peck strategies.
    public struct DrillingOperation: Sendable {
        public var contour: Contour
        public var tool: ToolParams
        public var settings: MachineSettings
        public var peckDepth: Double?

        public init(contour: Contour,
                    tool: ToolParams,
                    settings: MachineSettings,
                    peckDepth: Double? = nil) {
            self.contour = contour
            self.tool = tool
            self.settings = settings
            self.peckDepth = peckDepth
        }
    }
}
