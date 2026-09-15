//
//  DemoCounterbore.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 15.09.2026.
//

import Foundation
import StratumCAM
import SwiftDXF

class DemoCounterbore: Demo {

    // MARK: - Fixtures
    // Mirrors the fixtures in Counterbore_Tests.swift so each demo below reproduces
    // the exact scenario a corresponding unit test asserts on.

    /// A single `.point` entity at the given coordinates, the minimal contour the
    /// engine recognizes as a hole location -- same recognition counterbore reuses
    /// from drilling's `drillPoint(for:)`.
    private func pointContour(_ x: Double, _ y: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(entity: .point(at: DXF.Point(x, y), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
    }

    /// Wraps a counterbore demo's own `DemoResult` with two dashed reference circles
    /// per hole: a small one at `tool.diameter`, marking the input point itself (a bare
    /// point contour has no linearizable boundary of its own -- see `run(contours:...)`'s
    /// own comment on that -- so without this there's nothing marking where the toolpath
    /// is even centered), and a larger one at the operation's requested finished
    /// `diameter`, so the yellow toolpath's outermost ring can be checked against it
    /// directly instead of only being checkable from the numbers.
    ///
    /// `ContentView.show(_:)` assumes the *last* batch in `result.batches` is always the
    /// toolpath batch and treats everything before it as static reference geometry
    /// (`Array(result.batches.dropLast())`) -- appending these circles after that last
    /// batch would get them silently dropped by that same `dropLast()`, so they're
    /// inserted just *before* it instead.
    private func withReferenceCircles(_ result: Demo.DemoResult, centers: [(Double, Double)], diameter: Double, tool: SC.ToolParams) -> Demo.DemoResult {
        var referenceBatches: [RenderBatch] = []
        for (x, y) in centers {
            let inputPoints = Demo.circleReferencePoints(centerX: x, centerY: y, diameter: tool.diameter)
            if let inputBatch = renderBatch(forPoints: inputPoints,
                                            color: SIMD4<Float>(0.2, 0.8, 1.0, 1.0),
                                            isDashed: true,
                                            dashLength: 0.4) {
                referenceBatches.append(inputBatch)
            }
            let targetPoints = Demo.circleReferencePoints(centerX: x, centerY: y, diameter: diameter)
            if let targetBatch = renderBatch(forPoints: targetPoints,
                                             color: SIMD4<Float>(0.2, 0.8, 1.0, 1.0),
                                             isDashed: true,
                                             dashLength: 0.4) {
                referenceBatches.append(targetBatch)
            }
        }

        var batches = result.batches
        if !result.toolpathPoints.isEmpty && !batches.isEmpty {
            // Keep the toolpath batch last -- see this method's own doc comment above.
            batches.insert(contentsOf: referenceBatches, at: batches.count - 1)
        } else {
            batches.append(contentsOf: referenceBatches)
        }

        return Demo.DemoResult(batches: batches, gcode: result.gcode, toolpathPoints: result.toolpathPoints, tool: result.tool)
    }

    // MARK: - Basic counterbore recess

    /// Demo a bore for a M1.6 screw with
    func demoPlainCounterbore() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 2.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3)

        let center = (5.0, 5.0)
        let diameter = 3.6
        let operation: SC.MachiningOperation = .counterbore(diameter: diameter, depth: 3.0, direction: .climb, entry: .plunge)

        let result = self.run(contour: pointContour(center.0, center.1), tool: tool, settings: settings, operation: operation)
        return withReferenceCircles(result, centers: [center], diameter: diameter, tool: tool)
    }

    // MARK: - Multi-pass depth

    /// A recess deeper than one stepdown -- mirrors "depth greater than one
    /// stepdown produces multiple passes reusing identical XY geometry": the same
    /// ring stack traced again at each of several Z depths on the way down to the
    /// counterbore's own `depth`, independent of `settings.targetDepth`.
    func demoCounterboreMultiPassDepth() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5), safeZ: 5.0, targetDepth: -999.0)

        let center = (3.0, 4.0)
        let diameter = 16.0
        let operation: SC.MachiningOperation = .counterbore(diameter: diameter, depth: 3.2, direction: .climb, entry: .plunge)

        let result = self.run(contour: pointContour(center.0, center.1), tool: tool, settings: settings, operation: operation)
        return withReferenceCircles(result, centers: [center], diameter: diameter, tool: tool)
    }

    // MARK: - Entry strategies

    /// A `.ramp` entry into the innermost ring instead of a straight plunge --
    /// converts the vertical load of the first stepdown into a shallow incline,
    /// same reasoning `.pocket`/`.contour` ramp entries already document.
    func demoCounterboreWithRampEntry() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -999.0)

        let center = (0.0, 0.0)
        let diameter = 20.0
        let operation: SC.MachiningOperation = .counterbore(diameter: diameter, depth: 1.0, direction: .climb, entry: .ramp(angleDegrees: 3.0))

        let result = self.run(contour: pointContour(center.0, center.1), tool: tool, settings: settings, operation: operation)
        return withReferenceCircles(result, centers: [center], diameter: diameter, tool: tool)
    }

    /// A `.helix` entry spiralling gradually down into the innermost ring rather
    /// than plunging straight down -- mirrors "a .helix entry spirals gradually
    /// down to depth rather than plunging straight down": several arc moves
    /// descending a bit further each turn, visible in the preview as a small
    /// downward spiral right before the ring stack starts.
    func demoCounterboreWithHelixEntry() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5), safeZ: 5.0, targetDepth: -999.0)

        let center = (0.0, 0.0)
        let diameter = 20.0
        let operation: SC.MachiningOperation = .counterbore(diameter: diameter, depth: 1.0, direction: .climb, entry: .helix(radius: 1.0, rampAngleDegrees: 30))

        let result = self.run(contour: pointContour(center.0, center.1), tool: tool, settings: settings, operation: operation)
        return withReferenceCircles(result, centers: [center], diameter: diameter, tool: tool)
    }

    // MARK: - Cut direction

    /// Same recess as `demoPlainCounterbore`, but wound `.conventional` instead
    /// of `.climb` -- every ring's winding flips (CCW instead of CW around the
    /// wall), same climb/conventional distinction `.boring`'s own circular pass
    /// already makes for an inside cut.
    func demoCounterboreConventional() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5), safeZ: 5.0, targetDepth: -999.0)

        let center = (5.0, 5.0)
        let diameter = 20.0
        let operation: SC.MachiningOperation = .counterbore(diameter: diameter, depth: 1.0, direction: .conventional, entry: .plunge)

        let result = self.run(contour: pointContour(center.0, center.1), tool: tool, settings: settings, operation: operation)
        return withReferenceCircles(result, centers: [center], diameter: diameter, tool: tool)
    }

    // MARK: - Multiple counterbores

    /// Counterbores a batch of independent point contours laid out as a
    /// rectangle -- mirrors the same "each hole gets its own toolpath" pattern
    /// `DemoBoring.demoMultipleBores` and `DemoDrilling.demoMultipleHoles` use,
    /// here with every hole sharing the same recess diameter, depth, and entry,
    /// and each hole getting its own pair of dashed reference circles.
    func demoMultipleCounterbores() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5), safeZ: 5.0, targetDepth: -999.0)

        let points = [
            (10.0, 10.0),
            (30.0, 10.0),
            (30.0, 30.0),
            (10.0, 30.0)
        ]
        let contours = points.map { pointContour($0.0, $0.1) }
        let diameter = 12.0

        let operation: SC.MachiningOperation = .counterbore(diameter: diameter, depth: 1.5, direction: .climb, entry: .plunge)

        let result = self.run(contours: contours, tool: tool, settings: settings, operation: operation)
        return withReferenceCircles(result, centers: points, diameter: diameter, tool: tool)
    }
}
