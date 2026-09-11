//
//  File.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import StratumCAM
import SwiftDXF

class DemoEngraving: Demo {

    /// This will engravea line with one single pass
    func demoLine() -> [RenderBatch] {
        let tool = SC.ToolParams(diameter: 3.175, stepdown: 0.1)

        let settings = SC.MachineSettings(feedRate: 1000.0,
                                          plungeRate: 300.0,
                                          safeZ: 5.0,
                                          targetDepth: 0.1)

        let lineEntity = DXF.Entity.line(a: DXF.Point(0, 0),
                                         b: DXF.Point(20, 0),
                                         layer: "0",
                                         color: 7)
        let contour = SC.Contour(
            entities: [
                SC.Contour.Chained(entity: lineEntity, reversed: false)
            ],
            isClosed: false
        )

        return self.getBatches(contour: contour, tool: tool, settings: settings, strategy: .engrave)
    }

    func demoLineMultiplePasses() -> [RenderBatch] {
        let tool = SC.ToolParams(diameter: 3.175, stepdown: 0.1)

        let settings = SC.MachineSettings(feedRate: 1000.0,
                                          plungeRate: 300.0,
                                          safeZ: 5.0,
                                          targetDepth: 1)

        let lineEntity = DXF.Entity.line(a: DXF.Point(0, 0),
                                         b: DXF.Point(20, 0),
                                         layer: "0",
                                         color: 7)
        let contour = SC.Contour(
            entities: [
                SC.Contour.Chained(entity: lineEntity, reversed: false)
            ],
            isClosed: false
        )

        return self.getBatches(contour: contour, tool: tool, settings: settings, strategy: .engrave)
    }
}
