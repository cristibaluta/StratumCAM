//
//  ContentView.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import SwiftUI
import MetalKit
import simd

struct ContentView: View {
    @State private var renderBatches: [RenderBatch] = []

    var body: some View {
        NavigationSplitView {
            // Sidebar Controls & Test Cases
            List {
                Section("Test Scenarios") {
                    Button("Square Profile") {
                        loadSquareGeometry()
                    }
                    Button("Clear Canvas") {
                        renderBatches = []
                    }
                }
            }
            .navigationTitle("StratumCAM")
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
        let dashedBatch = RenderBatch(vertexBuffer: dashedBuffer, vertexCount: dashedVertices.count, primitiveType: .lineStrip, isDashed: true, dashLength: 4.0)

        self.renderBatches = [baseBatch, dashedBatch]
    }
}
