//
//  ContentView.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import SwiftUI
import MetalKit
import simd
import StratumCAM
import SwiftDXF

struct ContentView: View {
    @State private var renderBatches: [RenderBatch] = []

    var body: some View {
        NavigationSplitView {
            // Sidebar Controls & Test Cases
            List {
                Section("Test Scenarios") {
                    Button("Clear Canvas") {
                        renderBatches = []
                    }
                    Button("Square Profile") {
                        loadSquareGeometry()
                    }
                    Button("Engrave Test") {
                        loadEngravingTest()
                    }
                }
            }
            .navigationTitle("StratumCAM Demo")
        } detail: {
            // Interactive 3D Metal Canvas
            MetalCanvasView(batches: $renderBatches)
                .overlay(alignment: .bottomLeading) {
                    Text("Controls: Drag to Orbit | Shift + Drag to Pan")
                        .font(.caption)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(6)
                        .padding()
                }
        }
        .onAppear {
            loadSquareGeometry()
        }
    }

    // MARK: - Geometry Generation

    private func loadSquareGeometry() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let halfSize: Float = 25.0

        // Base coordinates
        let rawPoints: [SIMD3<Float>] = [
            SIMD3<Float>(-halfSize, -halfSize, 0),
            SIMD3<Float>( halfSize, -halfSize, 0),
            SIMD3<Float>( halfSize,  halfSize, 0),
            SIMD3<Float>(-halfSize,  halfSize, 0),
            SIMD3<Float>(-halfSize, -halfSize, 0)
        ]

        // Helper to build RenderVertex array with computed path distances
        func buildVertices(points: [SIMD3<Float>], color: SIMD4<Float>, zOffset: Float) -> [RenderVertex] {
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

        // Layer 1: Solid Base Square (White/Cyan, Z = 0.0)
        let baseVertices = buildVertices(points: rawPoints, color: SIMD4<Float>(0.2, 0.8, 1.0, 1.0), zOffset: 0.0)
        let baseBuffer = device.makeBuffer(bytes: baseVertices, length: baseVertices.count * MemoryLayout<RenderVertex>.stride, options: .storageModeShared)!
        let baseBatch = RenderBatch(vertexBuffer: baseBuffer, vertexCount: baseVertices.count, primitiveType: .lineStrip)

        // Layer 2: Dashed Overlay Square (Yellow, Z = 0.1 offset to prevent Z-fighting)
        let dashedVertices = buildVertices(points: rawPoints, color: SIMD4<Float>(1.0, 0.8, 0.0, 1.0), zOffset: 0.1)
        let dashedBuffer = device.makeBuffer(bytes: dashedVertices, length: dashedVertices.count * MemoryLayout<RenderVertex>.stride, options: .storageModeShared)!
        let dashedBatch = RenderBatch(vertexBuffer: dashedBuffer, vertexCount: dashedVertices.count, primitiveType: .lineStrip, isDashed: true, dashLength: 1.0)

        self.renderBatches = [baseBatch, dashedBatch]
    }

    private func loadEngravingTest() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 3.175, stepdown: 0.1)
        let settings = SC.MachineSettings(feedRate: 1000.0,
                                          plungeRate: 300.0,
                                          safeZ: 5.0,
                                          targetDepth: -1.0)
        let lineEntity = DXF.Entity.line(a: DXF.Point(0, 0),
                                         b: DXF.Point(20, 0),
                                         layer: "0",
                                         color: 7)
        let contour = SC.Contour(
            entities: [
                SC.Contour.Chained(entity: lineEntity, reversed: false)
            ],
            isClosed: false
        )
        let toolpaths: [SC.OutputToolpath] = engine.generateToolpaths(from: [contour],
                                                                      tool: tool,
                                                                      settings: settings,
                                                                      strategy: .engrave)

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
        // Base coordinates
        var rawPoints: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(20, 0, 0)
        ]

        // Helper to build RenderVertex array with computed path distances
        func buildVertices(points: [SIMD3<Float>], color: SIMD4<Float>, zOffset: Float) -> [RenderVertex] {
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

        // Layer 1: Solid Base Square (White/Cyan, Z = 0.0)
        let baseVertices = buildVertices(points: rawPoints, color: SIMD4<Float>(0.2, 0.8, 1.0, 1.0), zOffset: 0.0)
        let baseBuffer = device.makeBuffer(bytes: baseVertices, length: baseVertices.count * MemoryLayout<RenderVertex>.stride, options: .storageModeShared)!
        let baseBatch = RenderBatch(vertexBuffer: baseBuffer, vertexCount: baseVertices.count, primitiveType: .lineStrip, isDashed: true, dashLength: 0.4)

        // Layer 2: Dashed Overlay Square (Yellow, Z = 0.1 offset to prevent Z-fighting)
        let dashedVertices = buildVertices(points: toolpathPoints, color: SIMD4<Float>(1.0, 0.8, 0.0, 1.0), zOffset: 0.1)
        let dashedBuffer = device.makeBuffer(bytes: dashedVertices, length: dashedVertices.count * MemoryLayout<RenderVertex>.stride, options: .storageModeShared)!
        let dashedBatch = RenderBatch(vertexBuffer: dashedBuffer, vertexCount: dashedVertices.count, primitiveType: .lineStrip)

        self.renderBatches = [baseBatch, dashedBatch]
    }
}
