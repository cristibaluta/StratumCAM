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

    /// A single closed `.circle` entity, the other shape `drillPoint` recognizes --
    /// common in DXF for marking hole centers since many CAD tools have no
    /// dedicated point primitive. `isClosed` must be `true` or it reads as
    /// engraveable geometry instead (see `Contour.drillPoint`).
    private func circleContour(center: (Double, Double), radius: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(entity: .circle(center: DXF.Point(center.0, center.1), radius: radius, layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    /// A closed 4-line square -- real, machinable geometry, but not a drill point:
    /// more than one entity, so `drillPoint` returns `nil` and `.drilling` throws
    /// `SC.Error.missingDrillPoint` rather than silently doing nothing.
    private func squareContour(origin: (Double, Double), size: Double) -> SC.Contour {
        let (x, y) = origin
        return SC.Contour(entities: [
            SC.Contour.Chained(entity: .line(a: DXF.Point(x, y), b: DXF.Point(x + size, y), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(x + size, y), b: DXF.Point(x + size, y + size), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(x + size, y + size), b: DXF.Point(x, y + size), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(x, y + size), b: DXF.Point(x, y), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    // MARK: - Basic drill cycle

    /// Plunges straight down at a single point and retracts to Safe Z. Mirrors
    /// "A plain drill cycle plunges straight down and retracts at the point
    /// location": rapid-plunge-retract, 3 waypoints in a single pass.
    func demoPlainDrill() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .drill)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -8.0)

        let operation: SC.MachiningOperation = .drilling(peckDepth: nil)

        return self.run(contour: pointContour(12, 20), tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Peck drilling

    /// Pecks down to target depth in evenly divisible steps, retracting to
    /// retractZ between pecks and to Safe Z on the final retract. Mirrors
    /// "Peck drilling with an evenly divisible depth produces exactly the
    /// right number of pecks": 8mm deep at a 4mm peck depth yields 2 pecks
    /// (5 waypoints: rapid, plunge, retract, plunge, retract).
    func demoPeckDrill() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .drill)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, retractZ: 1.0, targetDepth: 8.0)
        let operation: SC.MachiningOperation = .drilling(peckDepth: 3.0)

        return self.run(contour: pointContour(10, 10), tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Multiple drill points

    /// Drills four independent point contours laid out as a rectangle. Mirrors
    /// "Multiple drill point contours produce one toolpath per hole": each hole
    /// gets its own rapid-plunge-retract toolpath, all sharing the same tool,
    /// settings, and (non-peck) strategy.
    func demoMultipleHoles() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .drill)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: 8.0)

        let points = [
            (10.0, 20.0),
            (30.0, 20.0),
            (30.0, 40.0),
            (10.0, 40.0)
        ]
        let contours = points.map { pointContour($0.0, $0.1) }

        let operation: SC.MachiningOperation = .drilling(peckDepth: nil)

        return self.run(contours: contours, tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Circle as a drill point

    /// Drills a single closed `.circle` contour at its center. Mirrors "A drill
    /// cycle from a closed circle contour drills at the circle's center": the
    /// circle itself is never cut -- it's just how the hole location was marked --
    /// so only the plunge/retract toolpath shows at its center point, same as the
    /// point-contour demos above.
    func demoCircleDrill() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .drill, diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 250.0, stepdown: 1.0), safeZ: 6.0, targetDepth: -5.0)

        let operation: SC.MachiningOperation = .drilling(peckDepth: nil)

        return self.run(contour: circleContour(center: (1, 2), radius: 2.0), tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Non-drill-point geometry

    /// Points a `.drilling` operation at a square instead of a point or a closed
    /// circle. Mirrors "A non-drill-point contour throws missingDrillPoint": a
    /// square has real, closed, machinable geometry, but more than one entity, so
    /// `Contour.drillPoint` returns `nil` and the engine throws rather than
    /// guessing a hole location. `run(contour:...)` catches that (Step 6.2, see its
    /// own doc comment) and falls back to an empty toolpath, so this demo renders
    /// only the blue dashed square outline -- no yellow toolpath -- which is the
    /// visual point: this shape is not drillable, even though it's a perfectly
    /// valid contour for `.engrave`/`.contour`/`.pocket`.
    func demoSquareIsNotDrilled() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .drill, diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: 8.0)

        let operation: SC.MachiningOperation = .drilling(peckDepth: nil)

        return self.run(contour: squareContour(origin: (10, 10), size: 20), tool: tool, settings: settings, operation: operation)
    }
}
