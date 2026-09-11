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
    @State private var gcodeText: String = ""

    var body: some View {
        NavigationSplitView {
            // Sidebar Controls & Test Cases
            List {
                Section("Test Scenarios") {
                    Button("Clear Canvas") {
                        renderBatches = []
                        gcodeText = ""
                    }
                    Button("Engrave Line") {
                        show(DemoEngraving().demoLine())
                    }
                    Button("Square Profile") {
                        show(DemoEngraving().demoLineMultiplePasses())
                    }
                    Button("Engrave Letter S") {
                        show(DemoEngraving().demoLetterS())
                    }
                }
            }
            .navigationTitle("StratumCAM Demo")
        } content: {
            // G-code for the shape currently on the canvas
            ScrollView {
                Text(gcodeText.isEmpty ? "No G-code yet. Run a demo from the sidebar." : gcodeText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(gcodeText.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .navigationTitle("G-Code")
            .frame(minWidth: 260, idealWidth: 320)
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
            show(DemoEngraving().demoLine())
        }
    }

    private func show(_ result: Demo.DemoResult) {
        renderBatches = result.batches
        gcodeText = result.gcode
    }
}
