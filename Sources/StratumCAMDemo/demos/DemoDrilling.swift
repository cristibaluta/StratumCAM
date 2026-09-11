//
//  DemoDrilling.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import StratumCAM
import SwiftDXF

class DemoDrilling: Demo {

    // MARK: - Fixtures
    // Mirrors the fixtures in Drilling_Tests.swift so each demo below reproduces
    // the exact scenario a corresponding unit test asserts on.

    /// A single `.point` entity at the given coordinates, the minimal contour
    /// the engine recognizes as a drill point.
    private func pointContour(_ x: Double, _ y: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(entity: .point(at: DXF.Point(x, y), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
    }

    // MARK: - Basic drill cycle

    /// Plunges straight down at a single point and retracts to Safe Z. Mirrors
    /// "A plain drill cycle plunges straight down and retracts at the point
    /// location": rapid-plunge-retract, 3 waypoints in a single pass.
    func demoPlainDrill() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .drill, diameter: 3.0, stepdown: 1.0)
        let settings = SC.MachineSettings(feedRate: 1000.0, plungeRate: 200.0, safeZ: 5.0, targetDepth: -8.0)

        let strategy: SC.Strategy = .drilling(peckDepth: nil)

        return self.run(contour: pointContour(12, 20), tool: tool, settings: settings, strategy: strategy)
    }

    // MARK: - Peck drilling

    /// Pecks down to target depth in evenly divisible steps, retracting to
    /// retractZ between pecks and to Safe Z on the final retract. Mirrors
    /// "Peck drilling with an evenly divisible depth produces exactly the
    /// right number of pecks": 8mm deep at a 4mm peck depth yields 2 pecks
    /// (5 waypoints: rapid, plunge, retract, plunge, retract).
    func demoPeckDrill() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .drill, diameter: 3.0, stepdown: 1.0)
        let settings = SC.MachineSettings(feedRate: 1000.0, plungeRate: 200.0, safeZ: 5.0, retractZ: 1.0, targetDepth: 8.0)

        let strategy: SC.Strategy = .drilling(peckDepth: 4.0)

        return self.run(contour: pointContour(10, 10), tool: tool, settings: settings, strategy: strategy)
    }
}
