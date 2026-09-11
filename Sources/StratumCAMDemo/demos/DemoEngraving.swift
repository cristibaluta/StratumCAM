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
    func demoLine() -> Demo.DemoResult {
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

        return self.run(contour: contour, tool: tool, settings: settings, strategy: .engrave)
    }

    func demoLineMultiplePasses() -> Demo.DemoResult {
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

        return self.run(contour: contour, tool: tool, settings: settings, strategy: .engrave)
    }

    /// Engraves the character "S" as a single continuous pass, built from two
    /// chained arcs of equal radius curving in opposite directions (the same
    /// construction a stroke font uses for the letter's two humps).
    func demoLetterS() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175, stepdown: 0.1)

        let settings = SC.MachineSettings(feedRate: 1000.0,
                                          plungeRate: 300.0,
                                          safeZ: 5.0,
                                          targetDepth: 1.0)

        let radius = 5.0

        // Lower hump: sweeps from (0, 0) to (0, 10), bulging right through (radius, 5).
        let lowerArc = DXF.Entity.arc(center: DXF.Point(0, radius),
                                      radius: radius,
                                      startDeg: 270.0,
                                      endDeg: 90.0,
                                      layer: "0",
                                      color: 7)

        // Upper hump: sweeps from (0, 10) to (0, 20), bulging left through (-radius, 15).
        // Defined the same way as the lower arc but reversed, so it continues on
        // from where the lower arc ends while curving the opposite way.
        let upperArc = DXF.Entity.arc(center: DXF.Point(0, radius * 3),
                                      radius: radius,
                                      startDeg: 90.0,
                                      endDeg: 270.0,
                                      layer: "0",
                                      color: 7)

        let contour = SC.Contour(
            entities: [
                SC.Contour.Chained(entity: lowerArc, reversed: false),
                SC.Contour.Chained(entity: upperArc, reversed: true)
            ],
            isClosed: false
        )

        return self.run(contour: contour, tool: tool, settings: settings, strategy: .engrave)
    }
}
