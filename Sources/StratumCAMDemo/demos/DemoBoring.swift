//
//  DemoBoring.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//


//
//  DemoBoring.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation
import StratumCAM
import SwiftDXF

class DemoBoring: Demo {

    // MARK: - Fixtures
    // Mirrors the fixtures in Boring_Tests.swift so each demo below reproduces
    // the exact scenario a corresponding unit test asserts on.

    /// A single `.point` entity at the given coordinates, the minimal contour
    /// the engine recognizes as a hole location -- same recognition boring
    /// reuses from drilling's `drillPoint(for:)`.
    private func pointContour(_ x: Double, _ y: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(entity: .point(at: DXF.Point(x, y), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
    }

    // MARK: - Basic boring cycle (Step 2C.1)

    /// Rapids to the bore's edge, plunges, sweeps the full circle at
    /// `targetDiameter / 2` around the hole center, then retracts straight up.
    /// Mirrors "A basic boring cycle plunges at the hole's edge and orbits the
    /// center at the target radius": rapid-plunge-arc-arc-retract, 5 waypoints
    /// in a single pass.
    func demoPlainBore() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -8.0)

        let operation: SC.MachiningOperation = .boring(targetDiameter: 10.0, dwellTime: nil, shiftRetract: false)

        return self.run(contour: pointContour(12, 20), tool: tool, settings: settings, operation: operation)
    }

    /// Same cycle, but starting from a closed circle contour instead of a bare
    /// point -- mirrors "A boring cycle from a closed circle contour bores
    /// centered on the circle's center", the same DXF-marking convention
    /// drilling accepts.
    func demoBoreFromCircleContour() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 250.0, stepdown: 1.0), safeZ: 6.0, targetDepth: -5.0)

        let contour = SC.Contour(entities: [
            SC.Contour.Chained(entity: .circle(center: DXF.Point(20, 20), radius: 3.0, layer: "0", color: 7), reversed: false)
        ], isClosed: true)

        let operation: SC.MachiningOperation = .boring(targetDiameter: 8.0, dwellTime: nil, shiftRetract: false)

        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Dwell + shift retract (Step 2C.2)

    /// Pauses at the bottom of the bore (`G04`) right after the circular
    /// interpolation finishes, before retracting -- same waypoint shape as
    /// `demoPlainBore`, the dwell only shows up in the G-code panel, not as
    /// an extra move in the 3D preview.
    func demoBoreWithDwell() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -8.0)

        let operation: SC.MachiningOperation = .boring(targetDiameter: 10.0, dwellTime: 0.5, shiftRetract: false)

        return self.run(contour: pointContour(12, 20), tool: tool, settings: settings, operation: operation)
    }

    /// Shifts the tool inward off the freshly bored wall (toward the hole
    /// center, by the tool's own radius) before retracting, instead of lifting
    /// straight up from the bore's edge -- mirrors "shiftRetract on inserts a
    /// linear move off the wall, toward center, before retracting": one extra
    /// waypoint visible in the preview between the last arc and the retract.
    func demoBoreWithShiftRetract() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -8.0)

        let operation: SC.MachiningOperation = .boring(targetDiameter: 10.0, dwellTime: nil, shiftRetract: true)

        return self.run(contour: pointContour(12, 20), tool: tool, settings: settings, operation: operation)
    }

    /// Both together: dwell at the bottom, then shift off the wall, then
    /// retract -- mirrors "Boring dwell still lands right after the final arc
    /// when shiftRetract also inserts a move", the conventional fine-boring
    /// cycle order (cut -> dwell -> shift off the wall -> retract).
    func demoBoreWithDwellAndShiftRetract() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -8.0)

        let operation: SC.MachiningOperation = .boring(targetDiameter: 10.0, dwellTime: 0.5, shiftRetract: true)

        return self.run(contour: pointContour(12, 20), tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Multiple bores

    /// Bores four independent point contours laid out as a rectangle. Mirrors
    /// "Boring a batch of holes assigns each toolpath to its own hole
    /// location": each hole gets its own rapid-plunge-arc-arc-retract
    /// toolpath, all sharing the same tool, settings, and diameter.
    func demoMultipleBores() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -8.0)

        let points = [
            (10.0, 20.0),
            (30.0, 20.0),
            (30.0, 40.0),
            (10.0, 40.0)
        ]
        let contours = points.map { pointContour($0.0, $0.1) }

        let operation: SC.MachiningOperation = .boring(targetDiameter: 6.0, dwellTime: nil, shiftRetract: false)

        return self.run(contours: contours, tool: tool, settings: settings, operation: operation)
    }
}