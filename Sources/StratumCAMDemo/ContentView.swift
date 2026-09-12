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
    @State private var selectedDemoID: String? = nil

    var body: some View {
        NavigationSplitView {
            // Sidebar Controls & Test Cases
            List {
                Section("Engraving") {
                    demoButton("Engrave Line") {
                        show(DemoEngraving().demoLine())
                    }
                    demoButton("Square Profile") {
                        show(DemoEngraving().demoLineMultiplePasses())
                    }
                    demoButton("Engrave Letter S") {
                        show(DemoEngraving().demoLetterS())
                    }
                    demoButton("Engrave Word STRATUM") {
                        show(DemoEngraving().demoWordSTRATUM())
                    }
                }
                Section("Contours") {
                    demoButton("Outside Square") {
                        show(DemoContour().demoOutsideSquare())
                    }
                    demoButton("Inside Square") {
                        show(DemoContour().demoInsideSquare())
                    }
                    demoButton("Ramp Entry") {
                        show(DemoContour().demoRampEntry())
                    }
                    demoButton("Helix Entry") {
                        show(DemoContour().demoHelixEntry())
                    }
                    demoButton("Holding Tab") {
                        show(DemoContour().demoHoldingTab())
                    }
                }
                Section("Drilling") {
                    demoButton("Plain Drill") {
                        show(DemoDrilling().demoPlainDrill())
                    }
                    demoButton("Peck Drill") {
                        show(DemoDrilling().demoPeckDrill())
                    }
                    demoButton("Multiple Holes") {
                        show(DemoDrilling().demoMultipleHoles())
                    }
                }
                Section("Pocketing") {
                    demoButton("Rectangle (Climb)") {
                        show(DemoPocketing().demoPocketRectangle())
                    }
                    demoButton("Rectangle (Conventional)") {
                        show(DemoPocketing().demoPocketRectangleConventional())
                    }
                    demoButton("Rounded Rectangle") {
                        show(DemoPocketing().demoPocketRoundedRectangle())
                    }
                    demoButton("Multi-pass Z Stepdown") {
                        show(DemoPocketing().demoMultiPassZStepdown())
                    }
                    demoButton("Raster Multi-pass Z Stepdown") {
                        show(DemoPocketing().demoRasterMultiPassZStepdown())
                    }
                    demoButton("Ring Geometry Reused Across Passes") {
                        show(DemoPocketing().demoRingGeometryReusedAcrossPasses())
                    }
                    demoButton("Ramp Entry (Multi-pass)") {
                        show(DemoPocketing().demoRampEntryMultiPass())
                    }
                    demoButton("Helix Entry (Multi-pass)") {
                        show(DemoPocketing().demoHelixEntryMultiPass())
                    }
                }
                Section("Pocketing — Raster") {
                    demoButton("Raster Rectangle (Climb)") {
                        show(DemoPocketing().demoRasterRectangle())
                    }
                    demoButton("Raster Rectangle (Conventional)") {
                        show(DemoPocketing().demoRasterRectangleConventional())
                    }
                    demoButton("Raster Rounded Rectangle") {
                        show(DemoPocketing().demoRasterRoundedRectangle())
                    }
                    demoButton("Raster Ramp Entry") {
                        show(DemoPocketing().demoRasterRampEntry())
                    }
                    demoButton("Raster Helix Entry") {
                        show(DemoPocketing().demoRasterHelixEntry())
                    }
                    demoButton("Concave Staple (Bridging Row Fix)") {
                        show(DemoPocketing().demoRasterConcaveStapleSkipsBridgingRows())
                    }
                }
                Section("Pocketing — Spiral") {
                    demoButton("Spiral Circle") {
                        show(DemoPocketing().demoSpiralCircle())
                    }
                    demoButton("Spiral Fallback on Rectangle") {
                        show(DemoPocketing().demoSpiralFallbackOnRectangle())
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
            selectedDemoID = "Engrave Word STRATUM"
            show(DemoEngraving().demoWordSTRATUM())
        }
    }

    /// A sidebar row that highlights itself when it was the last demo run, so the
    /// current 3D preview/G-code always has an obvious source in the list -- handy
    /// once a section has this many similarly-named buttons in it.
    private func demoButton(_ title: String, action: @escaping () -> Void) -> some View {
        let isSelected = selectedDemoID == title

        return Button {
            selectedDemoID = title
            action()
        } label: {
            Text(title)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    private func show(_ result: Demo.DemoResult) {
        renderBatches = result.batches
        gcodeText = result.gcode
    }
}
