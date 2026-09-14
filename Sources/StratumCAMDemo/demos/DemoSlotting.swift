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
    // Only real-world boundary-driven scenarios are kept here -- centerline-only
    // fixtures (a bare straight line/L-shape/circle handed straight to
    // `.slotting`) are useful for exercising the underlying engine directly in
    // `Slotting_Tests.swift`, but nobody actually draws a slot as its own
    // centerline in CAD, so they don't earn a demo of their own.

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

    /// An open-ended ("U") slot boundary -- two parallel walls `width` apart,
    /// joined by a closed short end, with the opposite short end left off
    /// entirely, since that's where the slot runs off the edge of the stock into
    /// free air. `length` is measured from the open mouth to the closed end; the
    /// mouth itself sits at x=0, the closed end at x=length. Matches the fixture
    /// `Slotting_Tests.swift` uses for open-ended boundary recognition.
    private func openEndedSlotBoundaryContour(length: Double, width: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(length, 0), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(length, 0), b: DXF.Point(length, width), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(length, width), b: DXF.Point(0, width), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
    }

    // MARK: - Rectangle boundary -> derived centerline (real-world blind slot)

    /// The real-world blind-slot case: instead of handing `.slotting` a centerline
    /// directly, draw the slot's actual physical boundary -- a plain 30x6mm
    /// rectangle, width matching the 6mm tool exactly -- and derive the centerline
    /// from it via `rectangleSlotCenterline(fromBoundary:tool:)`. The blue reference
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
        if let bbox = Demo.boundingBox(of: boundaryPoints, toolpathPoints),
           let stockBatch = stockBatch(stock: Demo.syntheticStock(around: bbox, tool: tool, settings: settings)) {
            batches.append(stockBatch)
        }
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

    // MARK: - Open-ended boundary -> derived centerline (real-world open slot)

    /// The real-world open-ended-slot case: the slot's boundary is a "U" -- open
    /// on the end that runs off the edge of the stock into free air -- rather than
    /// a fully closed rectangle. Because there's no material beyond that open end,
    /// the tool never needs to plunge into solid stock at all: it rapids down in
    /// free air just outside the part, then feeds sideways into the material.
    /// `entry: .fromOpenEnd` drives that feed-in as a chain of overlapping
    /// trochoidal loops (reusing the same `trochoidalSegments` machinery
    /// `.pocket`'s own `.trochoidal` pattern uses) rather than a single full-width
    /// straight-line feed, so the cutter engages gradually loop by loop instead of
    /// slamming to full width the instant it crosses into the stock.
    ///
    /// `openEndedSlotCenterline(fromBoundary:tool:)` derives that centerline from
    /// the boundary the same way `rectangleSlotCenterline` does for the blind case:
    /// inset by the tool radius at the closed end (rounding what a round tool can't
    /// cut square), but *extended past* the open mouth by one tool diameter so the
    /// first trochoidal loop starts entirely clear of the stock.
    func demoSlottingOpenEnded() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: -1.0)
        let boundary = openEndedSlotBoundaryContour(length: 30, width: 6)

        guard let centerline = engine.openEndedSlotCenterline(fromBoundary: boundary, tool: tool) else {
            // Shouldn't happen for this fixture -- the boundary's own width
            // matches the tool exactly -- but a demo should never crash even if
            // the fixture above is ever edited to no longer qualify.
            return Demo.DemoResult(batches: [], gcode: "", toolpathPoints: [], tool: tool)
        }

        // Blue reference: the boundary itself (the physical slot walls that will
        // exist once the open end has been cut), not the derived centerline.
        let boundarySegments = engine.linearize(contour: boundary)
        let boundaryWaypoints = engine.buildWaypoints(for: boundarySegments, atZ: 0, settings: settings)
        let boundaryPoints = tessellateForRender(boundaryWaypoints)

        let toolpaths = engine.generateToolpaths(
            from: [centerline],
            tool: tool,
            settings: settings,
            operation: .slotting(depthPerPass: 1.0, entry: .fromOpenEnd(stepoverPercentage: 0.5))
        )
        var toolpathPoints: [SIMD3<Float>] = []
        for toolpath in toolpaths {
            for pass in toolpath.passes {
                toolpathPoints.append(contentsOf: tessellateForRender(pass.waypoints))
            }
        }

        var batches: [RenderBatch] = []
        if let bbox = Demo.boundingBox(of: boundaryPoints, toolpathPoints),
           let stockBatch = stockBatch(stock: Demo.syntheticStock(around: bbox, tool: tool, settings: settings)) {
            batches.append(stockBatch)
        }
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
