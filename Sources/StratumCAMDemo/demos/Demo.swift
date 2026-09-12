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

        return DemoResult(batches: batches, gcode: gcode, toolpathPoints: toolpathPoints)
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

    /// `buildWaypoints`/toolpath passes only carry the *endpoints* of each move (plus a
    /// center + direction for arcs) since that's all a real controller needs for `G02`/`G03`.
    /// For the on-screen preview we need actual curvature, so this walks the waypoints and,
    /// for any `arcCW`/`arcCCW` motion, inserts interpolated points along the true arc between
    /// the previous waypoint and this one instead of drawing a straight chord between them.
    private func tessellateForRender(_ waypoints: [SC.Waypoint], segmentsPerArc: Int = 32) -> [SIMD3<Float>] {
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
