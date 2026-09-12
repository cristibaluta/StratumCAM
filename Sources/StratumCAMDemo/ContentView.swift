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
                Section("Engraving") {
                    Button("Engrave Line") {
                        show(DemoEngraving().demoLine())
                    }
                    Button("Square Profile") {
                        show(DemoEngraving().demoLineMultiplePasses())
                    }
                    Button("Engrave Letter S") {
                        show(DemoEngraving().demoLetterS())
                    }
                    Button("Engrave Word STRATUM") {
                        show(DemoEngraving().demoWordSTRATUM())
                    }
                }
                Section("Contours") {
                    Button("Outside Square") {
                        show(DemoContour().demoOutsideSquare())
                    }
                    Button("Inside Square") {
                        show(DemoContour().demoInsideSquare())
                    }
                    Button("Ramp Entry") {
                        show(DemoContour().demoRampEntry())
                    }
                    Button("Helix Entry") {
                        show(DemoContour().demoHelixEntry())
                    }
                    Button("Holding Tab") {
                        show(DemoContour().demoHoldingTab())
                    }
                }
                Section("Drilling") {
                    Button("Plain Drill") {
                        show(DemoDrilling().demoPlainDrill())
                    }
                    Button("Peck Drill") {
                        show(DemoDrilling().demoPeckDrill())
                    }
                    Button("Multiple Holes") {
                        show(DemoDrilling().demoMultipleHoles())
                    }
                }
                Section("Pocketing") {
                    Button("Rectangle (Climb)") {
                        show(DemoPocketing().demoPocketRectangle())
                    }
                    Button("Rectangle (Conventional)") {
                        show(DemoPocketing().demoPocketRectangleConventional())
                    }
                    Button("Rounded Rectangle") {
                        show(DemoPocketing().demoPocketRoundedRectangle())
                    }
                    Button("Multi-pass Z Stepdown") {
                        show(DemoPocketing().demoMultiPassZStepdown())
                    }
                    Button("Raster Multi-pass Z Stepdown") {
                        show(DemoPocketing().demoRasterMultiPassZStepdown())
                    }
                    Button("Ring Geometry Reused Across Passes") {
                        show(DemoPocketing().demoRingGeometryReusedAcrossPasses())
                    }
                    Button("Ramp Entry (Multi-pass)") {
                        show(DemoPocketing().demoRampEntryMultiPass())
                    }
                    Button("Helix Entry (Multi-pass)") {
                        show(DemoPocketing().demoHelixEntryMultiPass())
                    }
                }
                Section("Pocketing — Raster") {
                    Button("Raster Rectangle (Climb)") {
                        show(DemoPocketing().demoRasterRectangle())
                    }
                    Button("Raster Rectangle (Conventional)") {
                        show(DemoPocketing().demoRasterRectangleConventional())
                    }
                    Button("Raster Rounded Rectangle") {
                        show(DemoPocketing().demoRasterRoundedRectangle())
                    }
                    Button("Raster Ramp Entry") {
                        show(DemoPocketing().demoRasterRampEntry())
                    }
                    Button("Raster Helix Entry") {
                        show(DemoPocketing().demoRasterHelixEntry())
                    }
                    Button("Concave Staple (Bridging Row Fix)") {
                        show(DemoPocketing().demoRasterConcaveStapleSkipsBridgingRows())
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
            show(DemoEngraving().demoWordSTRATUM())
        }
    }

    private func show(_ result: Demo.DemoResult) {
        renderBatches = result.batches
        gcodeText = result.gcode
    }
}
