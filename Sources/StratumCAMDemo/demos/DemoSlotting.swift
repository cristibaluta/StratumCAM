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

    /// A both-ends-open ("screw head") slot boundary -- just the two parallel side
    /// walls, `width` apart, with *neither* short end drawn: the slot runs off the
    /// edge of the stock on both sides into free air, the way a screwdriver slot
    /// runs clean across the head rather than stopping short anywhere. Each wall is
    /// its own independent segment (no shared corner to chain them, unlike the
    /// single-open-end "U"'s 3 segments), one from x=0 to x=length, the other drawn
    /// the same direction so `bothEndsOpenSlotCenterline`'s nearest-end pairing has
    /// an unambiguous match either way. Matches the fixture
    /// `Slotting_Tests.swift` will use for both-ends-open boundary recognition.
    private func bothEndsOpenSlotBoundaryContour(length: Double, width: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(length, 0), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(0, width), b: DXF.Point(length, width), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
    }

    // MARK: - Stock sizing for open-ended slots

    /// A synthetic stock block for a slot that runs off the edge of the stock on
    /// one or both ends -- unlike `Demo.syntheticStock` (built for a fully closed
    /// boundary, margin padded on every side), an open mouth's wall should sit
    /// flush with the stock's own edge, the same way a real screw-head slot's
    /// walls run right up to the part's edge rather than floating with clearance
    /// around them. `openMinX`/`openMaxX`, when provided, pin that edge of the
    /// stock to the boundary's own mouth coordinate (no margin); when `nil` (a
    /// closed end still inside solid material, e.g. the single-open-end case's
    /// far side), that edge falls back to the usual tool-scaled margin past the
    /// combined boundary+toolpath bounding box, same as `Demo.syntheticStock`.
    /// The Y (width) direction and Z (depth) always get that same margin/backing,
    /// since only the slot's own long axis ever runs off the stock.
    private func stockForOpenEndedSlot(boundaryPoints: [SIMD3<Float>],
                                       toolpathPoints: [SIMD3<Float>],
                                       openMinX: Double?,
                                       openMaxX: Double?,
                                       tool: SC.ToolParams,
                                       settings: SC.MachineSettings) -> SC.Stock? {
        guard let bbox = Demo.boundingBox(of: boundaryPoints, toolpathPoints) else {
            return nil
        }

        let margin = max(4.0, tool.diameter * 1.5)
        let backingMargin = 2.0

        let minX = openMinX ?? (Double(bbox.minX) - margin)
        let maxX = openMaxX ?? (Double(bbox.maxX) + margin)

        return SC.Stock(width: maxX - minX,
                        height: Double(bbox.maxY - bbox.minY) + margin * 2,
                        thickness: abs(settings.targetDepth) + backingMargin,
                        origin: SIMD3<Double>(minX, Double(bbox.minY) - margin, 0))
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
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)
        let boundary = rectangleBoundaryContour(length: 30, width: 6)
        let pattern = SC.SlotClearingPattern.trochoidal(settings: SC.TrochoidalSettings(radialEngagement: 50, loopRadius: 0))

        guard let centerline = engine.rectangleSlotCenterline(fromBoundary: boundary, tool: tool) else {
            // Shouldn't happen for this fixture -- the rectangle's own width
            // matches the tool exactly -- but a demo should never crash even if
            // the fixture above is ever edited to no longer qualify.
            return Demo.DemoResult(batches: [], gcode: "", toolpathPoints: [], tool: tool)
        }

        // Blue reference: the boundary itself (the physical slot walls), not the
        // derived centerline -- mirrors `run(facing:)`'s own split between a
        // Stock-derived reference rectangle and a separately-generated toolpath.
        let boundarySegments = boundary.linearizedSegments
        let boundaryWaypoints = engine.buildWaypoints(for: boundarySegments, atZ: 0, settings: settings)
        let boundaryPoints = tessellateForRender(boundaryWaypoints)

        // `generateToolpaths(from: [SC.Contour], ...)` has thrown since Step 6.2 --
        // same non-throwing-`run`-helper, catch-and-log fallback `Demo.run(contours:...)`
        // uses, since this demo builds its own result directly rather than going
        // through that shared helper (it needs two independent reference geometries --
        // the boundary for blue, the derived centerline for yellow -- see
        // `tessellateForRender`'s own doc comment on why `DemoSlotting` bypasses `run`).
        let toolpaths: [SC.OutputToolpath]
        do {
            toolpaths = try engine.generateToolpaths(
                from: [centerline],
                tool: tool,
                settings: settings,
                operation: .slotting(depthPerPass: 1.0, pattern: pattern, entry: .ramp(angleDegrees: 3))
            )
        } catch {
            print("generateToolpaths failed: \(error)")
            toolpaths = []
        }
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
    /// trochoidal bounces (`openEndedTrochoidalSegments`) rather than a single
    /// full-width straight-line feed, so the cutter engages gradually bite by
    /// bite instead of slamming to full width the instant it crosses into the
    /// stock.
    ///
    /// This slot is deliberately wider (8mm) than the 6mm tool cutting it, the
    /// realistic case the trochoidal bounce exists for: a same-width slot has no
    /// room for the tool center to bounce in at all (see
    /// `openEndedTrochoidalSegments`'s own doc comment on its `wallOffset == 0`
    /// fallback). `openEndedSlotCenterline(fromBoundary:tool:)` derives the
    /// centerline running down the middle of those two walls -- inset by the
    /// tool radius at the closed end (rounding what a round tool can't cut
    /// square), extended past the open mouth by one tool diameter so the first
    /// bounce starts entirely clear of the stock -- and `wallOffset` (the gap
    /// `(width - tool.diameter) / 2` the tool's own *center* is actually free to
    /// wander within, not the tool radius itself) is threaded through as this
    /// pattern's own `TrochoidalSettings.loopRadius`, exactly what
    /// `openEndedTrochoidalSegments` needs to keep the cutter genuinely
    /// constrained between the slot's own two real walls rather than bouncing
    /// the wrong amount.
    func demoSlottingOpenEnded() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)
        let width = 8.0
        let boundary = openEndedSlotBoundaryContour(length: 30, width: width)
        let wallOffset = (width - tool.diameter) / 2.0
        let pattern: SC.SlotClearingPattern =
            .trochoidal(settings: SC.TrochoidalSettings(radialEngagement: 0.5, loopRadius: wallOffset))

        guard let centerline = engine.openEndedSlotCenterline(fromBoundary: boundary, tool: tool) else {
            // Shouldn't happen for this fixture -- the "U"'s own closed end is at
            // least as wide as the tool -- but a demo should never crash even if
            // the fixture above is ever edited to no longer qualify.
            return Demo.DemoResult(batches: [], gcode: "", toolpathPoints: [], tool: tool)
        }

        // Blue reference: the boundary itself (the physical slot walls that will
        // exist once the open end has been cut), not the derived centerline.
        let boundarySegments = boundary.linearizedSegments
        let boundaryWaypoints = engine.buildWaypoints(for: boundarySegments, atZ: 0, settings: settings)
        let boundaryPoints = tessellateForRender(boundaryWaypoints)

        // See the earlier `demoSlottingRectangleBoundary`'s own comment on why this
        // catches rather than propagating `throws`.
        let toolpaths: [SC.OutputToolpath]
        do {
            toolpaths = try engine.generateToolpaths(
                from: [centerline],
                tool: tool,
                settings: settings,
                operation: .slotting(depthPerPass: 1.0, pattern: pattern, entry: .fromOpenEnd(stepoverPercentage: 0.5))
            )
        } catch {
            print("generateToolpaths failed: \(error)")
            toolpaths = []
        }
        var toolpathPoints: [SIMD3<Float>] = []
        for toolpath in toolpaths {
            for pass in toolpath.passes {
                toolpathPoints.append(contentsOf: tessellateForRender(pass.waypoints))
            }
        }

        // Purple stock: flush with the open mouth (x=0) -- no margin on that side,
        // since that's exactly where the stock's own edge is -- but the usual
        // tool-scaled margin past the closed end (x=length), which is still
        // surrounded by solid material.
        var batches: [RenderBatch] = []
        if let stock = stockForOpenEndedSlot(boundaryPoints: boundaryPoints,
                                             toolpathPoints: toolpathPoints,
                                             openMinX: 0,
                                             openMaxX: nil,
                                             tool: tool,
                                             settings: settings),
           let stockBatch = stockBatch(stock: stock) {
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

    // MARK: - Both-ends-open boundary -> derived centerline (real-world "screw head" slot)

    /// The real-world both-ends-open case: the slot's boundary is just its two
    /// parallel side walls, open to free air on *both* ends rather than closed on
    /// one -- the classic screwdriver slot, cut straight across the part. Neither
    /// end needs a plunge/ramp/helix into solid material, and neither end needs a
    /// tool-radius inset the way a closed corner does: the tool rapids down in
    /// free air just outside one edge, feeds in via overlapping trochoidal
    /// bounces (`entry: .fromOpenEnd`, same mechanism `demoSlottingOpenEnded`
    /// uses) across the full length, and exits into free air on the far side
    /// exactly the same way it entered.
    ///
    /// Same 8mm-wide-with-a-6mm-tool sizing as `demoSlottingOpenEnded`, and for
    /// the same reason -- see that function's own doc comment on why the
    /// trochoidal bounce needs a slot wider than the tool to have anything to
    /// bounce within at all. `bothEndsOpenSlotCenterline(fromBoundary:tool:)`
    /// derives that centerline from the boundary the same way
    /// `openEndedSlotCenterline` does for the single-open-end case, just
    /// extended past *both* mouths by one tool diameter instead of only one, and
    /// `wallOffset` (`(width - tool.diameter) / 2`) is threaded through as this
    /// pattern's own `TrochoidalSettings.loopRadius`, exactly as
    /// `demoSlottingOpenEnded` does.
    ///
    /// Both mouths sit exactly on the stock's own X edges in this demo (no margin
    /// on either side, same `stockForOpenEndedSlot` helper `demoSlottingOpenEnded`
    /// uses), so the preview reads the way a real screw head does: the slot
    /// running clean across the part rather than floating inset from its edges.
    func demoSlottingBothEndsOpen() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)
        let length = 30.0
        let width = 8.0
        let boundary = bothEndsOpenSlotBoundaryContour(length: length, width: width)
        let wallOffset = (width - tool.diameter) / 2.0
        let pattern = SC.SlotClearingPattern.trochoidal(settings: SC.TrochoidalSettings(radialEngagement: 0.5, loopRadius: wallOffset))

        guard let centerline = engine.bothEndsOpenSlotCenterline(fromBoundary: boundary, tool: tool) else {
            // Shouldn't happen for this fixture -- the boundary's own width is at
            // least as wide as the tool -- but a demo should never crash even if
            // the fixture above is ever edited to no longer qualify.
            return Demo.DemoResult(batches: [], gcode: "", toolpathPoints: [], tool: tool)
        }

        // Blue reference: the boundary itself (the physical slot walls that will
        // exist once both open ends have been cut), not the derived centerline.
        let boundarySegments = boundary.linearizedSegments
        let boundaryWaypoints = engine.buildWaypoints(for: boundarySegments, atZ: 0, settings: settings)
        let boundaryPoints = tessellateForRender(boundaryWaypoints)

        // See `demoSlottingRectangleBoundary`'s own comment on why this catches
        // rather than propagating `throws`.
        let toolpaths: [SC.OutputToolpath]
        do {
            toolpaths = try engine.generateToolpaths(
                from: [centerline],
                tool: tool,
                settings: settings,
                operation: .slotting(depthPerPass: 1.0, pattern: pattern, entry: .fromOpenEnd(stepoverPercentage: 0.5))
            )
        } catch {
            print("generateToolpaths failed: \(error)")
            toolpaths = []
        }
        var toolpathPoints: [SIMD3<Float>] = []
        for toolpath in toolpaths {
            for pass in toolpath.passes {
                toolpathPoints.append(contentsOf: tessellateForRender(pass.waypoints))
            }
        }

        // Purple stock: flush with both mouths (x=0 and x=length) -- no margin on
        // either end, since the slot genuinely spans the full stock, edge to edge.
        var batches: [RenderBatch] = []
        if let stock = stockForOpenEndedSlot(boundaryPoints: boundaryPoints,
                                             toolpathPoints: toolpathPoints,
                                             openMinX: 0,
                                             openMaxX: length,
                                             tool: tool,
                                             settings: settings),
           let stockBatch = stockBatch(stock: stock) {
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
