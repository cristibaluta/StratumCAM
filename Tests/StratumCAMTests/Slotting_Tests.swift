//
//  Slotting_Tests.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
import simd
@testable import StratumCAM

// Step 2B.3: `.slotting` coverage. 2B.1 traces the contour's own centerline
// directly (no `offsetContour` call -- a slot cuts full width on the curve
// itself, matching `CutSide.onContour`'s own doc comment) and 2B.2 wired in
// `calculateZPasses` stepdown plus `EntryStrategy` (plunge/ramp/helix), reusing
// `.contour`'s `rampWaypoints`/`helixEntryWaypoints` the same way `.pocket`
// already does. These tests cover: no lateral offset from the centerline,
// correct pass count/depths for a given total depth, and entry waypoints
// present for ramp/helix (mirroring `PocketEntry_Tests.swift`'s shape for the
// same three entry cases).

struct Slotting_Tests {

    // MARK: - Fixtures

    /// A single 20mm straight line along X, from (0,0) to (20,0) -- an open
    /// (non-closed) contour, since a slot's centerline has no reason to close
    /// back on itself the way a pocket boundary does.
    private func straightLineContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
    }

    /// An open L-shaped centerline: (0,0) -> (20,0) -> (20,10). Useful for
    /// confirming every vertex of a multi-segment slot lands exactly on the
    /// original centerline, not just a single straight run.
    private func lShapedContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 0), b: DXF.Point(20, 10), layer: "0", color: 7), reversed: false)
        ], isClosed: false)
    }

    private func slottingStrategy(depthPerPass: Double, entry: SC.EntryStrategy = .plunge) -> SC.MachiningOperation {
        let pattern = SC.SlotClearingPattern.raster
        return .slotting(depthPerPass: depthPerPass, pattern: pattern, entry: entry)
    }

    // MARK: - Centerline: no lateral offset

    @Test("Slotting traces the centerline directly, with no lateral (tool-radius) offset")
    func testSlottingFollowsCenterlineWithNoOffset() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [straightLineContour()],
            tool: tool,
            settings: settings,
            operation: slottingStrategy(depthPerPass: 1.0)
        )

        #expect(toolpaths.count == 1, "Test Failed: expected 1 slotting toolpath")
        let waypoints = toolpaths[0].passes[0].waypoints

        // rapid above start, plunge at start, trace to end, retract -- no ramp/helix
        // since entry defaults to .plunge.
        #expect(waypoints.count == 4, "Test Failed: expected rapid+plunge+trace+retract, got \(waypoints.count)")

        // Unlike `.contour`, which would offset a 6mm tool 3mm to one side, every
        // traced XY position must land exactly on the original centerline (y=0)
        // -- a larger tool changes nothing about where the path runs.
        for waypoint in waypoints {
            #expect(abs(waypoint.position.y - 0.0) < 1e-9,
                    "Test Failed: expected every waypoint to stay on the centerline (y=0), got y=\(waypoint.position.y)")
        }

        let xs = waypoints.map { $0.position.x }
        #expect(abs((xs.min() ?? -1) - 0.0) < 1e-9, "Test Failed: expected the path to start at the centerline's own x=0")
        #expect(abs((xs.max() ?? -1) - 20.0) < 1e-9, "Test Failed: expected the path to end at the centerline's own x=20, not offset by the tool radius")
    }

    @Test("A larger tool diameter does not change the traced XY path")
    func testSlottingOffsetIsIndependentOfToolDiameter() {
        let engine = SCEngine()
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let smallToolWaypoints = engine.generateToolpaths(
            from: [straightLineContour()],
            tool: SC.ToolParams(diameter: 3.0),
            settings: settings,
            operation: slottingStrategy(depthPerPass: 1.0)
        )[0].passes[0].waypoints

        let bigToolWaypoints = engine.generateToolpaths(
            from: [straightLineContour()],
            tool: SC.ToolParams(diameter: 12.0),
            settings: settings,
            operation: slottingStrategy(depthPerPass: 1.0)
        )[0].passes[0].waypoints

        #expect(smallToolWaypoints.count == bigToolWaypoints.count,
                "Test Failed: expected tool diameter to have no bearing on waypoint count")
        for (small, big) in zip(smallToolWaypoints, bigToolWaypoints) {
            #expect(abs(small.position.x - big.position.x) < 1e-9 && abs(small.position.y - big.position.y) < 1e-9,
                    "Test Failed: expected identical XY paths regardless of tool diameter")
        }
    }

    @Test("Slotting traces a multi-segment centerline exactly, vertex for vertex")
    func testSlottingTracesMultiSegmentCenterlineExactly() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpaths = engine.generateToolpaths(
            from: [lShapedContour()],
            tool: tool,
            settings: settings,
            operation: slottingStrategy(depthPerPass: 1.0)
        )
        let waypoints = toolpaths[0].passes[0].waypoints

        // rapid + plunge + 2 traced segment-ends + retract.
        #expect(waypoints.count == 5, "Test Failed: expected rapid+plunge+2 traced ends+retract, got \(waypoints.count)")

        let expectedTracedPoints: [(Double, Double)] = [(0, 0), (20, 0), (20, 10)]
        let tracedPoints = waypoints[1..<4].map { ($0.position.x, $0.position.y) }
        for ((ex, ey), (ax, ay)) in zip(expectedTracedPoints, tracedPoints) {
            #expect(abs(ex - ax) < 1e-9 && abs(ey - ay) < 1e-9,
                    "Test Failed: expected traced point (\(ex), \(ey)), got (\(ax), \(ay))")
        }
    }

    // MARK: - Multi-pass Z stepdown

    @Test("Slotting honors calculateZPasses for an unevenly divisible depth")
    func testSlottingMultiPassZDepthsMatchCalculateZPasses() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        // -2.5 / 1.0 -> rounds up to 3 passes: -1.0, -2.0, -2.5 (same fencepost rule
        // `calculateZPasses` covers in `ZPasses_Tests.swift`, and `.pocket` already
        // relies on in `PocketZPasses_Tests.swift`).
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0),
                                          safeZ: 5.0,
                                          targetDepth: -2.5)

        let toolpaths = engine.generateToolpaths(
            from: [straightLineContour()],
            tool: tool,
            settings: settings,
            operation: slottingStrategy(depthPerPass: 1.0)
        )

        let toolpath = toolpaths[0]
        #expect(toolpath.passes.count == 3, "Test Failed: expected 3 Z passes, got \(toolpath.passes.count)")
        #expect(toolpath.passes.map { $0.depthZ } == [-1.0, -2.0, -2.5],
                "Test Failed: expected pass depths [-1.0, -2.0, -2.5], got \(toolpath.passes.map { $0.depthZ })")
    }

    @Test("Slotting's centerline geometry is reused unchanged across every Z pass")
    func testSlottingGeometryReusedAcrossZPasses() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0),
                                          safeZ: 5.0,
                                          targetDepth: -3.0)

        let toolpath = engine.generateToolpaths(
            from: [straightLineContour()],
            tool: tool,
            settings: settings,
            operation: slottingStrategy(depthPerPass: 1.0)
        )[0]

        #expect(toolpath.passes.count == 3, "Test Failed: expected 3 Z passes")

        // Every pass should trace the exact same XY path (just at its own depth) --
        // proof the centerline is linearized once and reused, not regenerated (and
        // potentially drifting) per pass.
        let xsPerPass = toolpath.passes.map { pass in pass.waypoints.map { $0.position.x } }
        for xs in xsPerPass {
            #expect(xs == xsPerPass[0], "Test Failed: expected identical X sequence across every Z pass")
        }
    }

    @Test("A single evenly-divisible depth produces exactly one pass at that depth")
    func testSlottingSinglePassWhenDepthMatchesStepdown() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpath = engine.generateToolpaths(
            from: [straightLineContour()],
            tool: tool,
            settings: settings,
            operation: slottingStrategy(depthPerPass: 1.0)
        )[0]

        #expect(toolpath.passes.count == 1, "Test Failed: expected exactly 1 pass")
        #expect(toolpath.passes[0].depthZ == -1.0, "Test Failed: expected the single pass at -1.0")
    }

    // MARK: - Entry: plunge (default)

    @Test("Slotting's plunge entry retracts to safeZ and re-plunges straight down on every pass")
    func testSlottingPlungeEntryRetractsAndRePlungesEachPass() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0),
                                          safeZ: 5.0,
                                          targetDepth: -2.0)

        let toolpath = engine.generateToolpaths(
            from: [straightLineContour()],
            tool: tool,
            settings: settings,
            operation: slottingStrategy(depthPerPass: 1.0, entry: .plunge)
        )[0]

        #expect(toolpath.passes.count == 2, "Test Failed: expected 2 passes")

        for pass in toolpath.passes {
            let first = pass.waypoints.first!
            #expect(first.position.z == settings.safeZ, "Test Failed: expected every pass's plunge entry to start each pass with a rapid at safeZ")
            if case .rapid = first.motion {} else {
                Issue.record("Test Failed: first waypoint motion must be .rapid")
            }

            let last = pass.waypoints.last!
            #expect(last.position.z == settings.safeZ, "Test Failed: expected every pass to retract to safeZ")
        }
    }

    // MARK: - Entry: ramp

    @Test("Slotting ramp entry descends from previousZ down to the pass's own target depth, then traces the centerline")
    func testSlottingRampEntryDescendsFromPreviousZ() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0),
                                          safeZ: 5.0,
                                          targetDepth: -2.0)

        let toolpath = engine.generateToolpaths(
            from: [straightLineContour()],
            tool: tool,
            settings: settings,
            operation: slottingStrategy(depthPerPass: 1.0, entry: .ramp(angleDegrees: 20))
        )[0]

        #expect(toolpath.passes.count == 2, "Test Failed: expected 2 passes")

        // Pass 0 ramps from top-of-stock (previousZ = 0) down to -1.0; pass 1 ramps
        // from -1.0 down to -2.0 -- neither pass should ever go past its own target.
        let pass0 = toolpath.passes[0]
        let pass1 = toolpath.passes[1]

        #expect(!pass0.waypoints.contains { $0.position.z < -1.0 - 1e-9 },
                "Test Failed: pass 0's ramp should never cut deeper than its own target depth (-1.0)")
        #expect(!pass1.waypoints.contains { $0.position.z < -2.0 - 1e-9 },
                "Test Failed: pass 1's ramp should never cut deeper than its own target depth (-2.0)")

        // Every ramp still lands back exactly on the centerline's own start (0, 0)
        // at its pass's target depth, ready to hand off into the straight trace.
        let pass0LandsAtTarget = pass0.waypoints.contains { wp in
            abs(wp.position.x - 0.0) < 1e-6 && abs(wp.position.y - 0.0) < 1e-6 && abs(wp.position.z - (-1.0)) < 1e-6
        }
        #expect(pass0LandsAtTarget, "Test Failed: expected pass 0's ramp to land on the centerline start at -1.0")

        let pass1LandsAtTarget = pass1.waypoints.contains { wp in
            abs(wp.position.x - 0.0) < 1e-6 && abs(wp.position.y - 0.0) < 1e-6 && abs(wp.position.z - (-2.0)) < 1e-6
        }
        #expect(pass1LandsAtTarget, "Test Failed: expected pass 1's ramp to land on the centerline start at -2.0")

        // The centerline's far end (20, 0) should still appear at each pass's own
        // target depth -- the trace itself still runs after the ramp entry.
        for (pass, depth) in [(pass0, -1.0), (pass1, -2.0)] {
            let tracesEnd = pass.waypoints.contains { wp in
                abs(wp.position.x - 20.0) < 1e-6 && abs(wp.position.y - 0.0) < 1e-6 && abs(wp.position.z - depth) < 1e-6
            }
            #expect(tracesEnd, "Test Failed: expected the centerline's far end to still be traced at depth \(depth)")
        }
    }

    // MARK: - Entry: helix

    @Test("Slotting helix entry circles centered exactly on the centerline (no wall offset)")
    func testSlottingHelixEntryIsCenteredOnCenterline() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        let toolpath = engine.generateToolpaths(
            from: [straightLineContour()],
            tool: tool,
            settings: settings,
            operation: slottingStrategy(depthPerPass: 1.0, entry: .helix(radius: 2.0, rampAngleDegrees: 10))
        )[0]

        let waypoints = toolpath.passes[0].waypoints

        // The helix's own arc motions should appear somewhere in the waypoint list --
        // proof the `.helix` case actually took the `helixEntryWaypoints` branch
        // rather than silently falling through to a plain plunge.
        let hasArcMotion = waypoints.contains { wp in
            if case .arcCW = wp.motion { return true }
            if case .arcCCW = wp.motion { return true }
            return false
        }
        #expect(hasArcMotion, "Test Failed: expected the helix entry to contribute arc motion waypoints")

        // Because `side: .onContour` resolves the helix's internal offset to zero
        // (see `buildSlottingWaypoints`'s own doc comment), the helix circles
        // centered exactly on the centerline (y=0) -- every arc waypoint's center
        // reported by the motion itself should sit on y=0, not to one side of it.
        for wp in waypoints {
            switch wp.motion {
                case .arcCW(let center), .arcCCW(let center):
                    #expect(abs(center.y - 0.0) < 1e-6,
                            "Test Failed: expected the helix to be centered on the centerline (y=0), got center.y=\(center.y)")
                default:
                    break
            }
        }

        // The straight trace itself still runs afterwards, reaching the centerline's
        // far end at target depth.
        let tracesEnd = waypoints.contains { wp in
            abs(wp.position.x - 20.0) < 1e-6 && abs(wp.position.y - 0.0) < 1e-6 && abs(wp.position.z - (-1.0)) < 1e-6
        }
        #expect(tracesEnd, "Test Failed: expected the centerline's far end to still be traced after the helix entry")

        // Final waypoint retracts to safeZ.
        #expect(waypoints.last?.position.z == settings.safeZ, "Test Failed: expected the final retract to safeZ")
    }

    // MARK: - Batch

    // MARK: - Boundary recognition: rectangle -> centerline (real-world slot input)

    /// A plain axis-aligned rectangle boundary: 30mm long, 6mm wide (matching a
    /// 6mm tool exactly) -- the physical walls a same-width slot would actually
    /// leave behind, not its centerline.
    private func rectangleBoundaryContour(length: Double, width: Double) -> SC.Contour {
        SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(length, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(length, 0), b: DXF.Point(length, width), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(length, width), b: DXF.Point(0, width), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, width), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    @Test("A rectangle boundary matching the tool's diameter derives a centerline inset by the tool radius at each end")
    func testRectangleSlotCenterlineInsetsByToolRadius() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)

        // 30mm long, 6mm wide -- centerline should run from x=3 to x=27 (inset 3mm,
        // the tool radius, at each end) along y=3 (the rectangle's own mid-height).
        let boundary = rectangleBoundaryContour(length: 30, width: 6)
        let centerline = engine.rectangleSlotCenterline(fromBoundary: boundary, tool: tool)

        #expect(centerline != nil, "Test Failed: expected a valid centerline for a rectangle matching the tool's diameter")
        guard let centerline else { return }

        let segments = centerline.linearizedSegments
        #expect(segments.count == 1, "Test Failed: expected a single line segment as the derived centerline")
        guard case .line(let start, let end) = segments[0] else {
            Issue.record("Test Failed: expected the derived centerline to be a straight line")
            return
        }

        let xs = [start.x, end.x].sorted()
        #expect(abs(xs[0] - 3.0) < 1e-6, "Test Failed: expected the centerline to start inset 3mm (tool radius) from x=0")
        #expect(abs(xs[1] - 27.0) < 1e-6, "Test Failed: expected the centerline to end inset 3mm from x=30")
        #expect(abs(start.y - 3.0) < 1e-6 && abs(end.y - 3.0) < 1e-6,
                "Test Failed: expected the centerline to run along the rectangle's own mid-height (y=3)")
    }

    @Test("A rectangle's derived centerline, traced by the same tool, reproduces the original boundary's overall extents")
    func testRectangleSlotCenterlineReproducesBoundaryWhenTraced() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0), safeZ: 5.0, targetDepth: -1.0)
        let pattern = SC.SlotClearingPattern.raster

        let boundary = rectangleBoundaryContour(length: 30, width: 6)
        guard let centerline = engine.rectangleSlotCenterline(fromBoundary: boundary, tool: tool) else {
            Issue.record("Test Failed: expected a valid centerline")
            return
        }

        let toolpath = engine.generateToolpaths(
            from: [centerline],
            tool: tool,
            settings: settings,
            operation: .slotting(depthPerPass: 1.0, pattern: pattern, entry: .plunge)
        )[0]

        let xs = toolpath.passes[0].waypoints.map { $0.position.x }
        let toolRadius = tool.diameter / 2.0

        // The centerline itself runs x=[3,27]; the swept tool (radius 3mm) reaches
        // exactly x=[0,30] at either extreme -- the original rectangle's own length,
        // with the corners naturally rounded rather than left square.
        #expect(abs((xs.min() ?? -1) - toolRadius) < 1e-6, "Test Failed: expected the centerline's own near extent at x=3")
        #expect(abs((xs.max() ?? -1) - (30 - toolRadius)) < 1e-6, "Test Failed: expected the centerline's own far extent at x=27")
    }

    @Test("A rotated rectangle boundary still derives a correct centerline along its own long axis")
    func testRectangleSlotCenterlineHandlesRotatedRectangle() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 4.0)

        // Same 20mm x 4mm rectangle as the axis-aligned cases, but rotated 90°: long
        // axis now runs along Y instead of X.
        let boundary = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(0, 20), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, 20), b: DXF.Point(4, 20), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(4, 20), b: DXF.Point(4, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(4, 0), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)

        let centerline = engine.rectangleSlotCenterline(fromBoundary: boundary, tool: tool)
        #expect(centerline != nil, "Test Failed: expected a valid centerline for a rotated rectangle")
        guard let centerline else { return }

        let segments = centerline.linearizedSegments
        guard case .line(let start, let end) = segments[0] else {
            Issue.record("Test Failed: expected a straight line")
            return
        }

        #expect(abs(start.x - 2.0) < 1e-6 && abs(end.x - 2.0) < 1e-6,
                "Test Failed: expected the centerline to run along x=2 (the rectangle's own mid-width)")
        let ys = [start.y, end.y].sorted()
        #expect(abs(ys[0] - 2.0) < 1e-6 && abs(ys[1] - 18.0) < 1e-6,
                "Test Failed: expected the centerline to span y=[2,18], inset 2mm (tool radius) from each end")
    }

    @Test("A rectangle whose width doesn't match the tool's diameter yields no centerline")
    func testRectangleSlotCenterlineRejectsMismatchedWidth() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)

        // 30mm x 10mm -- neither side pairing is within tolerance of the 6mm tool.
        let boundary = rectangleBoundaryContour(length: 30, width: 10)

        #expect(engine.rectangleSlotCenterline(fromBoundary: boundary, tool: tool) == nil,
                "Test Failed: expected nil when neither side pairing matches the tool's own diameter")
    }

    @Test("A rectangle no longer than its own width yields no centerline")
    func testRectangleSlotCenterlineRejectsNoLongerThanWidth() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)

        // A perfect 6x6 square: width matches the tool, but there's no straight run
        // left once both ends are inset by the tool radius.
        let boundary = rectangleBoundaryContour(length: 6, width: 6)

        #expect(engine.rectangleSlotCenterline(fromBoundary: boundary, tool: tool) == nil,
                "Test Failed: expected nil for a rectangle no longer than its own width")
    }

    @Test("A non-rectangular quadrilateral yields no centerline")
    func testRectangleSlotCenterlineRejectsNonRectangularQuad() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)

        // A parallelogram (slanted sides), not a rectangle -- opposite sides are
        // equal length, but adjacent sides aren't perpendicular.
        let boundary = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(20, 0), b: DXF.Point(24, 6), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(24, 6), b: DXF.Point(4, 6), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(4, 6), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)

        #expect(engine.rectangleSlotCenterline(fromBoundary: boundary, tool: tool) == nil,
                "Test Failed: expected nil for a non-rectangular quadrilateral")
    }

    @Test("A boundary with a curved side yields no centerline (stadium shapes aren't handled by this path)")
    func testRectangleSlotCenterlineRejectsCurvedBoundary() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)

        // 2 straight sides + 2 semicircular caps -- a stadium/rounded-rectangle
        // boundary, not the plain 4-straight-side rectangle this path handles.
        let boundary = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(3, 0), b: DXF.Point(27, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .arc(center: DXF.Point(27, 3), radius: 3, startDeg: -90, endDeg: 90, layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(27, 6), b: DXF.Point(3, 6), layer: "0", color: 7), reversed: false),
            .init(entity: .arc(center: DXF.Point(3, 3), radius: 3, startDeg: 90, endDeg: 270, layer: "0", color: 7), reversed: false)
        ], isClosed: true)

        #expect(engine.rectangleSlotCenterline(fromBoundary: boundary, tool: tool) == nil,
                "Test Failed: expected nil for a boundary containing curved sides")
    }

    @Test("An open (non-closed) rectangle-shaped boundary yields no centerline")
    func testRectangleSlotCenterlineRejectsOpenBoundary() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)

        var openBoundary = rectangleBoundaryContour(length: 30, width: 6)
        openBoundary.isClosed = false

        #expect(engine.rectangleSlotCenterline(fromBoundary: openBoundary, tool: tool) == nil,
                "Test Failed: expected nil for a boundary that isn't closed")
    }

    // MARK: - Batch

    @Test("A batch of slotting contours produces one toolpath per contour, each honoring its own operation")
    func testSlottingBatchProducesOneToolpathPerContour() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0),
                                          safeZ: 5.0,
                                          targetDepth: -2.0)

        let toolpaths = engine.generateToolpaths(
            from: [straightLineContour(), lShapedContour()],
            tool: tool,
            settings: settings,
            operation: slottingStrategy(depthPerPass: 1.0)
        )

        #expect(toolpaths.count == 2, "Test Failed: expected one toolpath per contour")
        #expect(toolpaths[0].passes.count == 2 && toolpaths[1].passes.count == 2,
                "Test Failed: expected both toolpaths to honor the same 2-pass stepdown")
    }
}
