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

    /// A closed circle, radius 15 -- already usable directly as a slotting centerline
    /// (unlike the rectangle boundary below), since a single circle already fully
    /// specifies the closed path a same-width circular channel/groove would follow.
    /// No derivation needed here -- `buildSlottingToolpath` traces whatever contour
    /// it's handed, open or closed.
    private func circleContour(radius: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(entity: .circle(center: DXF.Point(0, 0), radius: radius, layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    /// A plain rectangle boundary -- the actual physical walls a same-width slot
    /// would leave behind, not its centerline. `length` runs along X, `width` along
    /// Y, corner at the origin. Matches the fixture in `Slotting_Tests.swift`'s
    /// boundary-recognition coverage.
    private func rectangleBoundaryContour(length: Double, width: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(length, 0), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(length, 0), b: DXF.Point(length, width), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(length, width), b: DXF.Point(0, width), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(0, width), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
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

    // MARK: - Closed circular channel (no derivation needed)

    /// A closed circular groove, radius 15mm, cut with a 4mm tool. Unlike the
    /// rectangle case below, this needs no boundary-recognition step at all --
    /// the circle drawn *is* the centerline already, so it's handed straight to
    /// `.slotting` the same way `demoSlottingStraightLine` hands over its line.
    /// Shown here specifically for contrast with `demoSlottingRectangleBoundary`
    /// below, which needs that extra derivation step to go from a boundary to a
    /// centerline in the first place.
    func demoSlottingClosedCircle() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .slotting(depthPerPass: 1.0, entry: .plunge)

        return self.run(contour: circleContour(radius: 15), tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Rectangle boundary -> derived centerline (real-world slot input)

    /// The real-world case: instead of handing `.slotting` a centerline directly,
    /// draw the slot's actual physical boundary -- a plain 30x6mm rectangle,
    /// width matching the 6mm tool exactly -- and derive the centerline from it
    /// via `rectangleSlotCenterline(fromBoundary:tool:)`. The blue reference
    /// drawn here is the boundary itself (what the finished slot's walls should
    /// look like), not the derived centerline, so the preview shows the
    /// yellow toolpath tracing a path inset from, and centered inside, the blue
    /// rectangle -- reaching the boundary's short ends exactly (rounding their
    /// square corners, since a round tool can't cut them square) rather than
    /// stopping short of or overshooting them.
    func demoSlottingRectangleBoundary() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: -1.0)
        let boundary = rectangleBoundaryContour(length: 30, width: 6)

        guard let centerline = engine.rectangleSlotCenterline(fromBoundary: boundary, tool: tool) else {
            // Shouldn't happen for this fixture -- the rectangle's own width
            // matches the tool exactly -- but a demo should never crash even if
            // the fixture above is ever edited to no longer qualify.
            return Demo.DemoResult(batches: [], gcode: "", toolpathPoints: [], tool: tool)
        }

        // Blue reference: the boundary itself (the physical slot walls), not the
        // derived centerline -- mirrors `run(facing:)`'s own split between a
        // Stock-derived reference rectangle and a separately-generated toolpath.
        let boundarySegments = engine.linearize(contour: boundary)
        let boundaryWaypoints = engine.buildWaypoints(for: boundarySegments, atZ: 0, settings: settings)
        let boundaryPoints = tessellateForRender(boundaryWaypoints)

        let toolpaths = engine.generateToolpaths(
            from: [centerline],
            tool: tool,
            settings: settings,
            operation: .slotting(depthPerPass: 1.0, entry: .plunge)
        )
        var toolpathPoints: [SIMD3<Float>] = []
        for toolpath in toolpaths {
            for pass in toolpath.passes {
                toolpathPoints.append(contentsOf: tessellateForRender(pass.waypoints))
            }
        }

        var batches: [RenderBatch] = []
        if let baseBatch = renderBatch(forPoints: boundaryPoints,
                                       color: SIMD4<Float>(0.2, 0.8, 1.0, 1.0),
                                       isDashed: true,
                                       dashLength: 0.4) {
            batches.append(baseBatch)
        }
        if let toolpathBatch = renderBatch(forPoints: toolpathPoints,
                                           color: SIMD4<Float>(1.0, 0.8, 0.0, 1.0)) {
            batches.append(toolpathBatch)
        }

        let gcode = gcodeEngine.generateGCode(from: toolpaths, settings: settings)

        return Demo.DemoResult(batches: batches, gcode: gcode, toolpathPoints: toolpathPoints, tool: tool)
    }
}
