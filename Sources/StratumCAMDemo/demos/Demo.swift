//
//  File.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import MetalKit
import simd
import StratumCAM
import SwiftDXF

class Demo {

    let device = MTLCreateSystemDefaultDevice()!
    let engine = SCEngine()
    let gcodeEngine = SCGCodeEngine()

    /// Everything a demo button needs to update the UI: the 3D preview batches,
    /// the G-code text for the same toolpath, and the raw toolpath points behind
    /// the prebuilt toolpath batch -- kept around (Step 5.1) so the UI layer can
    /// slice/scrub through them later instead of only ever drawing the whole
    /// toolpath at once. Every Z pass's points are flattened into one continuous
    /// array in the same order the full-toolpath batch already draws them in;
    /// per-pass boundaries aren't tracked yet (see ROADMAP.md Track 5.6).
    struct DemoResult {
        let batches: [RenderBatch]
        let gcode: String
        let toolpathPoints: [SIMD3<Float>]

        /// The tool used to generate this result's toolpaths, kept around so the
        /// UI layer's scrub marker (Step 5.3) can be sized from the *real* tool
        /// geometry -- diameter for the marker's own diameter, `fluteLength` for
        /// how tall to draw it -- instead of a fixed, arbitrary radius.
        let tool: SC.ToolParams
    }

    func run(contour: SC.Contour, tool: SC.ToolParams, settings: SC.MachineSettings, operation: SC.MachiningOperation) -> DemoResult {
        run(contours: [contour], tool: tool, settings: settings, operation: operation)
    }

    /// Same as `run(contour:tool:settings:strategy:)` but for demos with several
    /// independent contours sharing one tool/settings/strategy (e.g. a batch of
    /// drill holes) — mirrors the engine's own `generateToolpaths(from: [SC.Contour], ...)`.
    func run(contours: [SC.Contour], tool: SC.ToolParams, settings: SC.MachineSettings, operation: SC.MachiningOperation) -> DemoResult {

        // 1. Convert each Contour to 3D simd points
        var rawPoints: [SIMD3<Float>] = []
        for contour in contours {
            let segments = engine.linearize(contour: contour)
            let waypoints = engine.buildWaypoints(for: segments, atZ: 0, settings: settings)
            rawPoints.append(contentsOf: tessellateForRender(waypoints))
        }

        // 2. Convert Contours to toolpaths then to 3d simd points
        let toolpaths: [SC.OutputToolpath] = engine.generateToolpaths(from: contours,
                                                                      tool: tool,
                                                                      settings: settings,
                                                                      operation: operation)
        var toolpathPoints: [SIMD3<Float>] = []
        for toolpath in toolpaths {
            for pass in toolpath.passes {
                toolpathPoints.append(contentsOf: tessellateForRender(pass.waypoints))
            }
        }

        // 3. Build Contour vertices (blue and dashed)
        // Some contours (e.g. a drilling point) have no linearizable base path,
        // so rawPoints can legitimately be empty -- renderBatch(forPoints:...)
        // returns nil in that case and the batch is skipped entirely.
        var batches: [RenderBatch] = []
        if let baseBatch = renderBatch(forPoints: rawPoints,
                                       color: SIMD4<Float>(0.2, 0.8, 1.0, 1.0),
                                       isDashed: true,
                                       dashLength: 0.4) {
            batches.append(baseBatch)
        }

        // 4. Build toolpaths vertices (yellow)
        if let toolpathBatch = renderBatch(forPoints: toolpathPoints,
                                           color: SIMD4<Float>(1.0, 0.8, 0.0, 1.0)) {
            batches.append(toolpathBatch)
        }

        // 5. Generate G-code for the same toolpaths
        let gcode = gcodeEngine.generateGCode(from: toolpaths, settings: settings)

        return DemoResult(batches: batches, gcode: gcode, toolpathPoints: toolpathPoints, tool: tool)
    }

    /// Same three-step shape as `run(contours:...)` above, but for `.facing`
    /// (Step 2A.2's `SC.FacingOperation`): there's no `SC.Contour` to linearize for
    /// the blue reference geometry -- facing clears a `Stock`'s whole top-face
    /// footprint, not a selected contour (see `FacingOperation`'s doc comment) --
    /// so the reference drawn here is the stock's own top-face rectangle instead,
    /// closed back to its first corner so it reads as a boundary rather than an
    /// open zig-zag. Toolpath generation goes through
    /// `generateToolpaths(from operations: [SC.FacingOperation])` (Step 2A.2)
    /// rather than the per-contour overload `run(contours:...)` uses, since
    /// `.facing` can't go through the per-contour switch (Step 2A.1's flag).
    func run(facing operation: SC.FacingOperation) -> DemoResult {

        // 1. Reference geometry: the stock's own top-face rectangle at Z=0 (not the
        // extended facing footprint the toolpath actually sweeps) so the preview
        // shows the toolpath relative to the real part boundary underneath it.
        let stock = operation.stock
        let corners: [SIMD3<Float>] = [
            SIMD3<Float>(Float(stock.origin.x), Float(stock.origin.y), 0),
            SIMD3<Float>(Float(stock.origin.x + stock.width), Float(stock.origin.y), 0),
            SIMD3<Float>(Float(stock.origin.x + stock.width), Float(stock.origin.y + stock.height), 0),
            SIMD3<Float>(Float(stock.origin.x), Float(stock.origin.y + stock.height), 0),
            SIMD3<Float>(Float(stock.origin.x), Float(stock.origin.y), 0)
        ]

        // 2. Convert the FacingOperation to a toolpath then to 3d simd points, via
        // the Stock-driven overload Step 2A.2 added.
        let toolpaths = engine.generateToolpaths(from: [operation])
        var toolpathPoints: [SIMD3<Float>] = []
        for toolpath in toolpaths {
            for pass in toolpath.passes {
                toolpathPoints.append(contentsOf: tessellateForRender(pass.waypoints))
            }
        }

        // 3. Build batches the same way run(contours:...) does: blue dashed
        // reference, yellow toolpath.
        var batches: [RenderBatch] = []
        if let baseBatch = renderBatch(forPoints: corners,
                                       color: SIMD4<Float>(0.2, 0.8, 1.0, 1.0),
                                       isDashed: true,
                                       dashLength: 0.4) {
            batches.append(baseBatch)
        }
        if let toolpathBatch = renderBatch(forPoints: toolpathPoints,
                                           color: SIMD4<Float>(1.0, 0.8, 0.0, 1.0)) {
            batches.append(toolpathBatch)
        }

        // 4. Generate G-code for the same toolpaths.
        let gcode = gcodeEngine.generateGCode(from: toolpaths, settings: operation.settings)

        return DemoResult(batches: batches, gcode: gcode, toolpathPoints: toolpathPoints, tool: operation.tool)
    }

    // MARK: - Step 5.2: prefix-slice + reusable batch builder

    /// Returns just the point prefix up to and including `index`, clamped to
    /// the array's own bounds (a negative index clamps to the first point, an
    /// index past the end clamps to the last). Pure function, no Metal/device
    /// dependency -- deliberately kept separate from `renderBatch(forPoints:...)`
    /// below so it's testable on its own once Step 5.8 adds coverage for it.
    static func pointsPrefix(_ points: [SIMD3<Float>], upTo index: Int) -> [SIMD3<Float>] {
        guard !points.isEmpty else {
            return []
        }
        let clampedIndex = max(0, min(index, points.count - 1))
        return Array(points[0...clampedIndex])
    }

    // MARK: - Step 5.5: smooth marker interpolation between points

    /// Linearly interpolates a position between `points[floor(index)]` and
    /// `points[ceil(index)]` for a fractional `index` -- lets the marker glide
    /// smoothly between points on coarse paths (e.g. a rectangle's 4 corners)
    /// instead of jumping point-to-point, without changing the underlying point
    /// density or the drawn toolpath prefix, which stays index-based (see
    /// `pointsPrefix` above -- that one's unaffected by this). Pure function, no
    /// Metal/device dependency, same reasoning as `pointsPrefix`: testable on its
    /// own once Step 5.8 adds coverage (e.g. index 0.5 between two known points
    /// returns their midpoint; a whole-number index returns that point exactly).
    ///
    /// `index` is clamped into `0...(points.count - 1)` the same way
    /// `pointsPrefix` clamps its own `index`, so a scrub value past either end of
    /// the array still returns a sensible position instead of crashing. Returns
    /// `nil` only for an empty `points` array, where there's nothing to
    /// interpolate between.
    static func interpolatedPoint(_ points: [SIMD3<Float>], at index: Double) -> SIMD3<Float>? {
        guard !points.isEmpty else {
            return nil
        }
        let clampedIndex = max(0, min(index, Double(points.count - 1)))
        let lowerIndex = Int(clampedIndex.rounded(.down))
        let upperIndex = Int(clampedIndex.rounded(.up))
        let lower = points[lowerIndex]
        let upper = points[upperIndex]
        let t = Float(clampedIndex - Double(lowerIndex))
        return lower + (upper - lower) * t
    }

    /// Builds a single `.lineStrip` `RenderBatch` from an arbitrary point array --
    /// the same buffer-building steps `run(contours:...)` above already repeats
    /// once for the blue contour and once for the full yellow toolpath, pulled out
    /// here so a caller (Step 5.4's slider) can build a batch from just a *prefix*
    /// of the toolpath's points without duplicating that boilerplate a third time.
    /// Returns `nil` for an empty point array, the same "skip the batch" convention
    /// `run(contours:...)` already uses -- an empty `makeBuffer` call is invalid.
    func renderBatch(forPoints points: [SIMD3<Float>],
                     color: SIMD4<Float>,
                     isDashed: Bool = false,
                     dashLength: Float = 5.0) -> RenderBatch? {
        let vertices = buildVertices(points: points, color: color, zOffset: 0.0)
        guard !vertices.isEmpty,
              let buffer = device.makeBuffer(bytes: vertices,
                                             length: vertices.count * MemoryLayout<RenderVertex>.stride,
                                             options: .storageModeShared) else {
            return nil
        }
        return RenderBatch(vertexBuffer: buffer,
                           vertexCount: vertices.count,
                           primitiveType: .lineStrip,
                           isDashed: isDashed,
                           dashLength: dashLength)
    }

    // MARK: - Step 5.3: marker cylinder geometry at a point

    /// Generates a wireframe cylinder's worth of `RenderVertex`s centered on `point`
    /// -- a "you are here" marker sized to the actual tool doing the cutting, rather
    /// than an arbitrary fixed radius: `diameter` matches `SC.ToolParams.diameter`
    /// and `height` matches `SC.ToolParams.fluteLength`, so the marker reads as a
    /// scale silhouette of the tool itself, not just an abstract pointer.
    ///
    /// The cylinder's base ring sits flat in the XY plane at `point.z` -- the
    /// toolpath point being marked is where the tool's tip is, so the base is drawn
    /// there and the cylinder extends upward (+Z) by `height` to represent the
    /// flutes rising above the tip, matching a real end mill's geometry.
    ///
    /// Built as independent `.line` segments (two rings plus a handful of vertical
    /// struts) rather than one continuous `.lineStrip`: a strip can't visit two
    /// separate rings and the struts between them without doubling back over
    /// itself, so disconnected segments are the simplest way to draw all three
    /// pieces in a single vertex buffer/primitive call. `dist` is left at 0 for
    /// every vertex since the marker is never dashed (`isDashed` only matters for
    /// `.lineStrip` paths where distance-along-path drives the dash pattern in the
    /// fragment shader).
    static func markerCylinderVertices(at point: SIMD3<Float>,
                                       diameter: Float = 2.0,
                                       height: Float = 4.0,
                                       segments: Int = 28,
                                       strutCount: Int = 4,
                                       color: SIMD4<Float> = SIMD4<Float>(1.0, 0.05, 0.05, 1.0)) -> [RenderVertex] {
        let clampedSegments = max(3, segments)
        let radius = max(0, diameter) / 2
        let baseZ = point.z
        let topZ = point.z + height

        func ringPoint(_ i: Int, z: Float) -> SIMD3<Float> {
            let t = Float(i) / Float(clampedSegments)
            let angle = t * 2 * Float.pi
            let x = point.x + radius * cos(angle)
            let y = point.y + radius * sin(angle)
            return SIMD3<Float>(x, y, z)
        }

        var vertices: [RenderVertex] = []
        vertices.reserveCapacity(clampedSegments * 4 + max(0, strutCount) * 2)

        // Base and top rings, each as `.line` segment pairs (i -> i+1) rather than
        // a closed strip, so both rings can share one buffer with the struts below.
        for i in 0..<clampedSegments {
            vertices.append(RenderVertex(position: ringPoint(i, z: baseZ), color: color, dist: 0))
            vertices.append(RenderVertex(position: ringPoint(i + 1, z: baseZ), color: color, dist: 0))
        }
        for i in 0..<clampedSegments {
            vertices.append(RenderVertex(position: ringPoint(i, z: topZ), color: color, dist: 0))
            vertices.append(RenderVertex(position: ringPoint(i + 1, z: topZ), color: color, dist: 0))
        }

        // Vertical struts connecting the two rings, evenly spaced around the
        // circumference, so the shape reads as a cylinder rather than two
        // unconnected rings floating at different heights.
        let clampedStruts = max(0, strutCount)
        for s in 0..<clampedStruts {
            let i = (s * clampedSegments) / max(1, clampedStruts)
            vertices.append(RenderVertex(position: ringPoint(i, z: baseZ), color: color, dist: 0))
            vertices.append(RenderVertex(position: ringPoint(i, z: topZ), color: color, dist: 0))
        }

        return vertices
    }

    /// Builds the marker `RenderBatch` for a given point -- thin wrapper around
    /// `markerCylinderVertices(at:diameter:height:segments:strutCount:color:)` that
    /// turns the vertices into a GPU buffer the same way `renderBatch(forPoints:...)`
    /// does above. Kept as an instance method (not `static`) only because it needs
    /// `device` for the buffer, same split as `pointsPrefix`/`renderBatch` above.
    func markerBatch(at point: SIMD3<Float>,
                     diameter: Float = 2.0,
                     height: Float = 4.0,
                     segments: Int = 28,
                     strutCount: Int = 4,
                     color: SIMD4<Float> = SIMD4<Float>(1.0, 0.05, 0.05, 1.0)) -> RenderBatch? {
        let vertices = Demo.markerCylinderVertices(at: point,
                                                    diameter: diameter,
                                                    height: height,
                                                    segments: segments,
                                                    strutCount: strutCount,
                                                    color: color)
        guard !vertices.isEmpty,
              let buffer = device.makeBuffer(bytes: vertices,
                                             length: vertices.count * MemoryLayout<RenderVertex>.stride,
                                             options: .storageModeShared) else {
            return nil
        }
        return RenderBatch(vertexBuffer: buffer,
                           vertexCount: vertices.count,
                           primitiveType: .line)
    }

    /// `buildWaypoints`/toolpath passes only carry the *endpoints* of each move (plus a
    /// center + direction for arcs) since that's all a real controller needs for `G02`/`G03`.
    /// For the on-screen preview we need actual curvature, so this walks the waypoints and,
    /// for any `arcCW`/`arcCCW` motion, inserts interpolated points along the true arc between
    /// the previous waypoint and this one instead of drawing a straight chord between them.
    /// Internal rather than `private` so a subclass in another file (e.g.
    /// `DemoSlotting`'s boundary-recognition demos, which need to build a
    /// combined result from two different contours -- the physical boundary for
    /// the blue reference, a derived centerline for the yellow toolpath -- rather
    /// than the single shared contour `run(contour:...)` assumes) can tessellate
    /// its own waypoints the same way `run(contours:...)`/`run(facing:)` do,
    /// without duplicating this arc-interpolation logic a third time.
    func tessellateForRender(_ waypoints: [SC.Waypoint], segmentsPerArc: Int = 32) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        var previous: SC.Waypoint?

        for wp in waypoints {
            switch wp.motion {
                case .rapid, .linear:
                    points.append(SIMD3<Float>(Float(wp.position.x), Float(wp.position.y), Float(wp.position.z)))

                case .arcCW(let center), .arcCCW(let center):
                    guard let prev = previous else {
                        points.append(SIMD3<Float>(Float(wp.position.x), Float(wp.position.y), Float(wp.position.z)))
                        break
                    }

                    let isCCW: Bool
                    if case .arcCCW = wp.motion { isCCW = true } else { isCCW = false }

                    let cx = Double(center.x)
                    let cy = Double(center.y)
                    let radius = hypot(prev.position.x - cx, prev.position.y - cy)
                    let startAngle = atan2(prev.position.y - cy, prev.position.x - cx)
                    var endAngle = atan2(wp.position.y - cy, wp.position.x - cx)

                    // Walk from startAngle to endAngle in the requested direction, wrapping
                    // around as needed so a full sweep is taken rather than the short way.
                    if isCCW {
                        while endAngle <= startAngle { endAngle += 2 * .pi }
                    } else {
                        while endAngle >= startAngle { endAngle -= 2 * .pi }
                    }

                    let steps = max(2, segmentsPerArc)
                    for i in 1...steps {
                        let t = Double(i) / Double(steps)
                        let angle = startAngle + (endAngle - startAngle) * t
                        let x = cx + radius * cos(angle)
                        let y = cy + radius * sin(angle)
                        let z = prev.position.z + (wp.position.z - prev.position.z) * t
                        points.append(SIMD3<Float>(Float(x), Float(y), Float(z)))
                    }
            }
            previous = wp
        }

        return points
    }

    // Helper to build RenderVertex array with computed path distances
    private func buildVertices(points: [SIMD3<Float>], color: SIMD4<Float>, zOffset: Float) -> [RenderVertex] {
        var vertices: [RenderVertex] = []
        var totalDistance: Float = 0.0

        for i in 0..<points.count {
            let pt = SIMD3<Float>(points[i].x, points[i].y, points[i].z + zOffset)
            if i > 0 {
                totalDistance += simd_distance(points[i], points[i - 1])
            }
            vertices.append(RenderVertex(position: pt, color: color, dist: totalDistance))
        }
        return vertices
    }
}
