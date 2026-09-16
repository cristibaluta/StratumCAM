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

    /// A closed 4-line square -- not a point or a closed circle, so `drillPoint`
    /// alone wouldn't recognize it, but it's closed, so `closedShapeCenter` picks
    /// it up: `.drilling` resolves to its bounding-box center rather than
    /// throwing. This is the shape behind e.g. pre-drilling a stress-relief hole
    /// in the middle of a pocket boundary before running adaptive clearing on it.
    private func squareContour(origin: (Double, Double), size: Double) -> SC.Contour {
        let (x, y) = origin
        return SC.Contour(entities: [
            SC.Contour.Chained(entity: .line(a: DXF.Point(x, y), b: DXF.Point(x + size, y), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(x + size, y), b: DXF.Point(x + size, y + size), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(x + size, y + size), b: DXF.Point(x, y + size), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(x, y + size), b: DXF.Point(x, y), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    /// The same square, missing its last side and flagged open -- an open boundary
    /// has no well-defined center (`closedShapeCenter` returns `nil` for it, same
    /// as `drillPoint`), so `.drilling` still has nothing to fall back to and
    /// throws `SC.Error.missingDrillPoint`.
    private func openBracketContour(origin: (Double, Double), size: Double) -> SC.Contour {
        let (x, y) = origin
        return SC.Contour(entities: [
            SC.Contour.Chained(entity: .line(a: DXF.Point(x, y), b: DXF.Point(x + size, y), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(x + size, y), b: DXF.Point(x + size, y + size), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(x + size, y + size), b: DXF.Point(x, y + size), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
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

    // MARK: - Any closed shape drills at its center

    /// Points a `.drilling` operation at a plain closed square -- no point or
    /// circle marker anywhere. Mirrors "A closed square with no point/circle
    /// marker still drills, at its bounding-box center": the square itself is
    /// never cut, same as the circle demo above, but now any closed boundary
    /// works as the marker, not just a circle. This is the shape of the actual
    /// use case: pre-drilling a stress-relief hole in the middle of a pocket
    /// boundary before coming back over it with adaptive clearing.
    func demoSquareDrillsAtCenter() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .drill, diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -6.0)

        let operation: SC.MachiningOperation = .drilling(peckDepth: nil)

        return self.run(contour: squareContour(origin: (10, 10), size: 20), tool: tool, settings: settings, operation: operation)
    }

    /// Points `.drilling` at the same square, minus its last side and flagged
    /// open. Mirrors "An open, non-drill-point contour still throws
    /// missingDrillPoint": an open boundary has no well-defined center, so the
    /// engine throws rather than guessing one, and `run(contour:...)` (Step 6.2,
    /// see its own doc comment) catches that and falls back to an empty
    /// toolpath. This demo renders only the blue dashed bracket outline -- no
    /// yellow toolpath, no marker -- the contrast with "Square Drills at
    /// Center" above is the point: closed is drillable, open still isn't.
    func demoOpenShapeIsNotDrilled() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .drill, diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -6.0)

        let operation: SC.MachiningOperation = .drilling(peckDepth: nil)

        return self.run(contour: openBracketContour(origin: (10, 10), size: 20), tool: tool, settings: settings, operation: operation)
    }
}
