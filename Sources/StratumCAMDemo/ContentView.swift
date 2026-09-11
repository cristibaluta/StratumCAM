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
                    Button("Engrave Line") {
                        renderBatches = DemoEngraving().demoLine()
                    }
                    Button("Square Profile") {
                        renderBatches = DemoEngraving().demoLineMultiplePasses()
                    }
                    Button("Engrave Letter S") {
                        renderBatches = DemoEngraving().demoLetterS()
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
            renderBatches = DemoEngraving().demoLetterS()
        }
    }
}
