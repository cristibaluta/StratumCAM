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

    func getBatches(contour: SC.Contour, tool: SC.ToolParams, settings: SC.MachineSettings, strategy: SC.Strategy) -> [RenderBatch] {

        // 1. Convert Contour to 3D simd points
        var rawPoints: [SIMD3<Float>] = []
        let segments = engine.linearize(contour: contour)
        let waypoints = engine.buildWaypoints(for: segments, atZ: 0, settings: settings)
        for p in waypoints {
            rawPoints.append(
                SIMD3<Float>(Float(p.position.x), Float(p.position.y), Float(p.position.z))
            )
        }

        // 2. Convert Contour to toolpaths then to 3d simd points
        let toolpaths: [SC.OutputToolpath] = engine.generateToolpaths(from: [contour],
                                                                      tool: tool,
                                                                      settings: settings,
                                                                      strategy: strategy)
        var toolpathPoints: [SIMD3<Float>] = []
        for toolpath in toolpaths {
            for pass in toolpath.passes {
                for p in pass.waypoints {
                    toolpathPoints.append(
                        SIMD3<Float>(Float(p.position.x), Float(p.position.y), Float(p.position.z))
                    )
                }
            }
        }

        // 3. Build Contour vertices (blue and dashed)
        let baseVertices = buildVertices(points: rawPoints,
                                         color: SIMD4<Float>(0.2, 0.8, 1.0, 1.0),
                                         zOffset: 0.0)
        let baseBuffer = device.makeBuffer(bytes: baseVertices,
                                           length: baseVertices.count * MemoryLayout<RenderVertex>.stride,
                                           options: .storageModeShared)!
        let baseBatch = RenderBatch(vertexBuffer: baseBuffer,
                                    vertexCount: baseVertices.count,
                                    primitiveType: .lineStrip,
                                    isDashed: true,
                                    dashLength: 0.4)

        // 4. Build toolpaths vertices (yellow)
        let toolpathVertices = buildVertices(points: toolpathPoints,
                                             color: SIMD4<Float>(1.0, 0.8, 0.0, 1.0),
                                             zOffset: 0.0)
        let toolpathBuffer = device.makeBuffer(bytes: toolpathVertices,
                                               length: toolpathVertices.count * MemoryLayout<RenderVertex>.stride,
                                               options: .storageModeShared)!
        let toolpathBatch = RenderBatch(vertexBuffer: toolpathBuffer,
                                        vertexCount: toolpathVertices.count,
                                        primitiveType: .lineStrip)

        return [baseBatch, toolpathBatch]
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
