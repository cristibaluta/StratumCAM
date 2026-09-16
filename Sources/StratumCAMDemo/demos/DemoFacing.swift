//
//  DemoFacing.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation
import StratumCAM
import SwiftDXF

class DemoFacing: Demo {

    /// A closed rectangle contour standing in for the finished part's own shape.
    /// `.facing` sweeps this shape's bounding box (grown by `extensionLength`),
    /// not a separately tracked stock block -- so these demos pass the same kind
    /// of contour any other operation would, and only the area the part actually
    /// occupies gets faced, not whatever extra stock surrounds it.
    private func rectangleContour(width: Double, height: Double, originX: Double = 0, originY: Double = 0) -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(originX, originY), b: DXF.Point(originX + width, originY), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(originX + width, originY), b: DXF.Point(originX + width, originY + height), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(originX + width, originY + height), b: DXF.Point(originX, originY + height), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(originX, originY + height), b: DXF.Point(originX, originY), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    // MARK: - Basic facing pass

    /// Faces a 20x10 part shape with a 6mm tool, climb direction, no extension. Mirrors
    /// "Facing produces a single pass at target depth, rows chained into one
    /// continuous trace": rows spaced by the engine's own tool-derived stepover,
    /// chained into one rapid-plunge-trace-retract pass at -abs(targetDepth).
    func demoFacingRectangleClimb() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: 0.5)
        let contour = rectangleContour(width: 20, height: 10)

        return self.run(contour: contour, tool: tool, settings: settings, operation: .facing(direction: .climb, extensionLength: 0))
    }

    /// Same 20x10 footprint and tool as `demoFacingRectangleClimb`, but
    /// conventional direction -- mirrors "Facing scanline order flips with
    /// direction": the same row count and Z depth, just each row (starting with
    /// the first) traveling the opposite way.
    func demoFacingRectangleConventional() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: 0.5)
        let contour = rectangleContour(width: 20, height: 10)

        return self.run(contour: contour, tool: tool, settings: settings, operation: .facing(direction: .conventional, extensionLength: 0))
    }

    // MARK: - Extension length

    /// Faces the same 20x10 part shape but grows the swept footprint 4mm past every
    /// edge. Mirrors "Facing footprint includes extensionLength, wired end to
    /// end through the toolpath": the toolpath reaches [-4,24]x[-4,14] rather
    /// than stopping at the shape's own [0,20]x[0,10] bounding box -- visibly
    /// wider than `demoFacingRectangleClimb`'s toolpath relative to the same
    /// blue contour outline.
    func demoFacingRectangleWithExtension() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: 1.0)
        let contour = rectangleContour(width: 20, height: 10)

        return self.run(contour: contour, tool: tool, settings: settings, operation: .facing(direction: .climb, extensionLength: 4.0))
    }

    // MARK: - Smaller tool, tighter rows

    /// Faces a larger 60x40 part shape with a smaller 4mm tool -- since row spacing now
    /// comes from the tool's own diameter rather than a hand-picked stepover, a
    /// smaller tool alone produces several more, tighter rows chained together
    /// than the small-footprint demos above, closer to a real datum-facing pass.
    func demoFacingLargeStockSmallTool() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1500.0, plungeRate: 400.0), safeZ: 6.0, targetDepth: 0.3)
        let contour = rectangleContour(width: 60, height: 40)

        return self.run(contour: contour, tool: tool, settings: settings, operation: .facing(direction: .climb, extensionLength: 1.0))
    }

    // MARK: - Batch

    /// Faces two independent part shapes back to back with different tools/settings.
    /// `.facing` now goes through the same per-contour pipeline every other
    /// operation uses, so "batch" is just two ordinary `run(contour:...)` calls --
    /// shown together as one combined preview since `run` only returns one
    /// `DemoResult` at a time, so this stitches both results' batches/points together.
    func demoFacingBatch() -> Demo.DemoResult {
        let smallTool = SC.ToolParams(diameter: 6.0)
        let bigTool = SC.ToolParams(diameter: 10.0)
        let settingsA = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: 0.5)
        let settingsB = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1200.0, plungeRate: 350.0), safeZ: 8.0, targetDepth: 1.5)

        let firstContour = rectangleContour(width: 20, height: 10)
        let secondContour = rectangleContour(width: 30, height: 15, originX: 30)

        let firstResult = self.run(contour: firstContour, tool: smallTool, settings: settingsA,
                                   operation: .facing(direction: .climb, extensionLength: 0))
        let secondResult = self.run(contour: secondContour, tool: bigTool, settings: settingsB,
                                    operation: .facing(direction: .conventional, extensionLength: 2.0))

        // The combined toolpathPoints run first's points then second's, so the scrub
        // marker (which defaults to the very end) sits on `second`'s cut -- use its
        // tool for the marker's size rather than `first`'s.
        return Demo.DemoResult(batches: firstResult.batches + secondResult.batches,
                               gcode: firstResult.gcode + "\n\n" + secondResult.gcode,
                               toolpathPoints: firstResult.toolpathPoints + secondResult.toolpathPoints,
                               tool: bigTool)
    }
}
