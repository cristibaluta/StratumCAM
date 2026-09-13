//
//  DemoSlotting.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation
import StratumCAM
import SwiftDXF

class DemoSlotting: Demo {

    // MARK: - Fixtures
    // Mirrors the fixtures in Slotting_Tests.swift so each demo below reproduces
    // the exact scenario a corresponding unit test asserts on.

    /// A single 20mm straight centerline along X, from (0,0) to (20,0) -- an open
    /// (non-closed) contour, since a slot's centerline has no reason to close back
    /// on itself the way a pocket boundary does.
    private func straightLineContour() -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
    }

    /// An open L-shaped centerline: (0,0) -> (20,0) -> (20,10). Shows a slot
    /// tracing more than one straight run, vertex for vertex.
    private func lShapedContour() -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(20, 0), b: DXF.Point(20, 10), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
    }

    // MARK: - Basic slot (no entry, single pass)

    /// Cuts a straight 20mm slot in a single 1mm-deep pass with a plain plunge
    /// entry -- the simplest possible `.slotting` case, mirroring Step 2B.1's
    /// "no entry" scope. Traces the centerline directly at full cutter width,
    /// with no lateral offset the way `.contour` would apply for a 6mm tool.
    func demoSlottingStraightLine() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .slotting(depthPerPass: 1.0, entry: .plunge)

        return self.run(contour: straightLineContour(), tool: tool, settings: settings, operation: operation)
    }

    /// Same straight centerline, but an L-shaped one instead -- shows the slot
    /// following multiple chained segments rather than a single straight run,
    /// still with no lateral offset from either leg's own centerline.
    func demoSlottingLShape() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .slotting(depthPerPass: 1.0, entry: .plunge)

        return self.run(contour: lShapedContour(), tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Multi-pass Z stepdown (Step 2B.2)

    /// Cuts the same straight slot down to -2.5mm total depth at a 1mm stepdown --
    /// 3 Z passes (-1.0, -2.0, -2.5, same fencepost rule `calculateZPasses` already
    /// applies elsewhere), each pass re-plunging fresh since entry is still
    /// `.plunge`. Mirrors "Slotting honors calculateZPasses for an unevenly
    /// divisible depth".
    func demoSlottingMultiPass() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: -2.5)

        let operation: SC.MachiningOperation = .slotting(depthPerPass: 1.0, entry: .plunge)

        return self.run(contour: straightLineContour(), tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Entry: ramp

    /// Same 3-pass straight slot as `demoSlottingMultiPass`, but with a ramp
    /// entry: each pass descends at a shallow angle from the previous pass's
    /// depth down to its own, rather than plunging straight down every time.
    func demoSlottingRampEntry() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: -2.5)

        let operation: SC.MachiningOperation = .slotting(depthPerPass: 1.0, entry: .ramp(angleDegrees: 15))

        return self.run(contour: straightLineContour(), tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Entry: helix

    /// Same straight slot, single pass, but with a helix entry -- the tool
    /// circles down centered exactly on the centerline (no wall to offset away
    /// from the way `.pocket`'s helix does) before tracing the slot itself.
    func demoSlottingHelixEntry() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .slotting(depthPerPass: 1.0, entry: .helix(radius: 2.0, rampAngleDegrees: 10))

        return self.run(contour: straightLineContour(), tool: tool, settings: settings, operation: operation)
    }
}
