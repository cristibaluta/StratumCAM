//
//  DemoFacing.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation
import StratumCAM

class DemoFacing: Demo {

    private func rectangleStock(width: Double, height: Double, thickness: Double = 6.0) -> SC.Stock {
        SC.Stock(width: width, height: height, thickness: thickness, origin: .zero)
    }

    // MARK: - Basic facing pass

    /// Faces a 20x10 stock with a 6mm tool, climb direction, no extension. Mirrors
    /// "Facing produces a single pass at target depth, rows chained into one
    /// continuous trace": rows spaced by the engine's own tool-derived stepover,
    /// chained into one rapid-plunge-trace-retract pass at -abs(targetDepth).
    func demoFacingRectangleClimb() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: 0.5)
        let stock = rectangleStock(width: 20, height: 10)
        let operation = SC.FacingOperation(stock: stock, tool: tool, settings: settings, direction: .climb, extensionLength: 0)

        return self.run(facing: operation)
    }

    /// Same 20x10 footprint and tool as `demoFacingRectangleClimb`, but
    /// conventional direction -- mirrors "Facing scanline order flips with
    /// direction": the same row count and Z depth, just each row (starting with
    /// the first) traveling the opposite way.
    func demoFacingRectangleConventional() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: 0.5)
        let stock = rectangleStock(width: 20, height: 10)

        let operation = SC.FacingOperation(stock: stock, tool: tool, settings: settings, direction: .conventional, extensionLength: 0)

        return self.run(facing: operation)
    }

    // MARK: - Extension length

    /// Faces the same 20x10 stock but grows the swept footprint 4mm past every
    /// edge. Mirrors "Facing footprint includes extensionLength, wired end to
    /// end through the toolpath": the toolpath reaches [-4,24]x[-4,14] rather
    /// than stopping at the stock's own [0,20]x[0,10] rectangle -- visibly
    /// wider than `demoFacingRectangleClimb`'s toolpath relative to the same
    /// blue stock outline.
    func demoFacingRectangleWithExtension() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: 1.0)
        let stock = rectangleStock(width: 20, height: 10)

        let operation = SC.FacingOperation(stock: stock, tool: tool, settings: settings, direction: .climb, extensionLength: 4.0)

        return self.run(facing: operation)
    }

    // MARK: - Smaller tool, tighter rows

    /// Faces a larger 60x40 stock with a smaller 4mm tool -- since row spacing now
    /// comes from the tool's own diameter rather than a hand-picked stepover, a
    /// smaller tool alone produces several more, tighter rows chained together
    /// than the small-footprint demos above, closer to a real datum-facing pass
    /// on a sheet of stock.
    func demoFacingLargeStockSmallTool() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1500.0, plungeRate: 400.0), safeZ: 6.0, targetDepth: 0.3)
        let stock = rectangleStock(width: 60, height: 40)

        let operation = SC.FacingOperation(stock: stock, tool: tool, settings: settings, direction: .climb, extensionLength: 1.0)

        return self.run(facing: operation)
    }

    // MARK: - Batch

    /// Faces two independent stocks back to back with different tools/settings
    /// via one `generateToolpaths(from: [SC.FacingOperation])` call. Mirrors "A
    /// batch of FacingOperations produces one toolpath per operation, independent
    /// settings" -- shown together as one combined preview since `run(facing:)`
    /// only takes one operation at a time; this demo runs the engine's batch
    /// entry point directly and stitches both results' batches/points together.
    func demoFacingBatch() -> Demo.DemoResult {
        let smallTool = SC.ToolParams(diameter: 6.0)
        let bigTool = SC.ToolParams(diameter: 10.0)
        let settingsA = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: 0.5)
        let settingsB = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1200.0, plungeRate: 350.0), safeZ: 8.0, targetDepth: 1.5)

        let first = SC.FacingOperation(stock: rectangleStock(width: 20, height: 10),
                                       tool: smallTool, settings: settingsA, direction: .climb, extensionLength: 0)
        let second = SC.FacingOperation(stock: rectangleStock(width: 30, height: 15, thickness: 6.0)
                                          .translated(x: 30, y: 0),
                                        tool: bigTool, settings: settingsB, direction: .conventional, extensionLength: 2.0)

        let firstResult = self.run(facing: first)
        let secondResult = self.run(facing: second)

        // The combined toolpathPoints run first's points then second's, so the scrub
        // marker (which defaults to the very end) sits on `second`'s cut -- use its
        // tool for the marker's size rather than `first`'s.
        return Demo.DemoResult(batches: firstResult.batches + secondResult.batches,
                               gcode: firstResult.gcode + "\n\n" + secondResult.gcode,
                               toolpathPoints: firstResult.toolpathPoints + secondResult.toolpathPoints,
                               tool: second.tool)
    }
}

private extension SC.Stock {
    /// Shifts this stock's origin by the given XY offset -- used by
    /// `demoFacingBatch` to lay its two stocks out side by side instead of
    /// overlapping at the same origin, purely for a legible combined preview.
    func translated(x: Double, y: Double) -> SC.Stock {
        var copy = self
        copy.origin.x += x
        copy.origin.y += y
        return copy
    }
}
