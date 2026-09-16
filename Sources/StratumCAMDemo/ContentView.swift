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
    @State private var toolpathPoints: [SIMD3<Float>] = []
    @State private var activeTool: SC.ToolParams = SC.ToolParams()
    @State private var scrubIndex: Double = 0
    @State private var staticBatches: [RenderBatch] = []

    private let previewDemo = Demo()

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
                Section("Contour") {
                    demoButton("Outside Square") {
                        show(DemoContour().demoOutsideSquare())
                    }
                    demoButton("Inside Square") {
                        show(DemoContour().demoInsideSquare())
                    }
                    demoButton("Ramp Entry prifiling") {
                        show(DemoContour().demoRampEntry())
                    }
                    demoButton("Helix Entry profiling") {
                        show(DemoContour().demoHelixEntry())
                    }
                    demoButton("Holding Tab") {
                        show(DemoContour().demoHoldingTab())
                    }
                    demoButton("Holding Tabs - Rectangle") {
                        show(DemoContour().demoHoldingTabRectangle())
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
                    demoButton("Circle as Drill Point") {
                        show(DemoDrilling().demoCircleDrill())
                    }
                    demoButton("Square Drills at Center") {
                        show(DemoDrilling().demoSquareDrillsAtCenter())
                    }
                    demoButton("Open Shape - Not Drilled") {
                        show(DemoDrilling().demoOpenShapeIsNotDrilled())
                    }
                }
                Section("Boring") {
                    demoButton("Plain Bore") {
                        show(DemoBoring().demoPlainBore())
                    }
                    demoButton("Bore from Circle Contour") {
                        show(DemoBoring().demoBoreFromCircleContour())
                    }
                    demoButton("Dwell") {
                        show(DemoBoring().demoBoreWithDwell())
                    }
                    demoButton("Shift Retract") {
                        show(DemoBoring().demoBoreWithShiftRetract())
                    }
                    demoButton("Dwell + Shift Retract") {
                        show(DemoBoring().demoBoreWithDwellAndShiftRetract())
                    }
                    demoButton("Multiple Bores") {
                        show(DemoBoring().demoMultipleBores())
                    }
                }
                Section("Counterbore") {
                    demoButton("Plain Counterbore") {
                        show(DemoCounterbore().demoPlainCounterbore())
                    }
                    demoButton("Multi-pass Depth") {
                        show(DemoCounterbore().demoCounterboreMultiPassDepth())
                    }
                    demoButton("Ramp Entry counterbore") {
                        show(DemoCounterbore().demoCounterboreWithRampEntry())
                    }
                    demoButton("Helix Entry counterbore") {
                        show(DemoCounterbore().demoCounterboreWithHelixEntry())
                    }
                    demoButton("Conventional Direction") {
                        show(DemoCounterbore().demoCounterboreConventional())
                    }
                    demoButton("Multiple Counterbores") {
                        show(DemoCounterbore().demoMultipleCounterbores())
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
                    Divider()
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
                    Divider()
                    demoButton("Spiral Circle insideOut") {
                        show(DemoPocketing().demoSpiralCircleInsideOut())
                    }
                    demoButton("Spiral Circle outsideIn") {
                        show(DemoPocketing().demoSpiralCircle())
                    }
                    demoButton("Spiral Fallback on Rectangle") {
                        show(DemoPocketing().demoSpiralFallbackOnRectangle())
                    }
                    Divider()
                    demoButton("Trochoidal Rectangle (Climb)") {
                        show(DemoPocketing().demoTrochoidalRectangle())
                    }
                    demoButton("Trochoidal Rectangle (Conventional)") {
                        show(DemoPocketing().demoTrochoidalRectangleConventional())
                    }
                    demoButton("Trochoidal Circle") {
                        show(DemoPocketing().demoTrochoidalCircle())
                    }
                }
                Section("Facing") {
                    demoButton("Rectangle (Climb)") {
                        show(DemoFacing().demoFacingRectangleClimb())
                    }
                    demoButton("Rectangle (Conventional)") {
                        show(DemoFacing().demoFacingRectangleConventional())
                    }
                    demoButton("Rectangle with Extension") {
                        show(DemoFacing().demoFacingRectangleWithExtension())
                    }
                    demoButton("Large Stock, Small Tool") {
                        show(DemoFacing().demoFacingLargeStockSmallTool())
                    }
                    demoButton("Batch (Two Stocks)") {
                        show(DemoFacing().demoFacingBatch())
                    }
                }
                Section("Slotting") {
                    demoButton("Rectangle Boundary (ramp entry)") {
                        show(DemoSlotting().demoSlottingRectangleBoundary())
                    }
                    demoButton("Open-Ended Boundary (Trochoidal Entry)") {
                        show(DemoSlotting().demoSlottingOpenEnded())
                    }
                    demoButton("Both Ends Open") {
                        show(DemoSlotting().demoSlottingBothEndsOpen())
                    }
                }
                Section("Thread Milling") {
                    demoButton("Internal M3") {
                        show(DemoThreadMilling().demoM3Internal())
                    }
                    demoButton("External M3") {
                        show(DemoThreadMilling().demoM3External())
                    }
                    demoButton("Multiple M3s") {
                        show(DemoThreadMilling().demoMultipleM3s())
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
                    VStack(alignment: .leading, spacing: 8) {
                        if !toolpathPoints.isEmpty {
                            HStack(spacing: 8) {
                                Text("Scrub")
                                    .font(.caption)
                                Slider(value: $scrubIndex, in: 0...Double(max(0, toolpathPoints.count - 1)))
                                    .onChange(of: scrubIndex) { _ in
                                        rebuildRenderBatches()
                                    }
                                    .frame(minWidth: 160)
                                Text("\(Int(scrubIndex.rounded())) / \(max(0, toolpathPoints.count - 1))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 56, alignment: .trailing)
                            }
                        }
                        Text("Controls: Drag to Orbit | Shift + Drag to Pan")
                            .font(.caption)
                    }
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
        gcodeText = result.gcode
        toolpathPoints = result.toolpathPoints
        activeTool = result.tool
        staticBatches = toolpathPoints.isEmpty ? result.batches : Array(result.batches.dropLast())
        scrubIndex = Double(max(0, toolpathPoints.count - 1))
        rebuildRenderBatches()
    }

    private func rebuildRenderBatches() {
        var batches = staticBatches
        if !toolpathPoints.isEmpty {
            let prefixIndex = Int(scrubIndex.rounded(.down))
            let prefix = Demo.pointsPrefix(toolpathPoints, upTo: prefixIndex)

            if let slicedBatch = previewDemo.renderBatch(forPoints: prefix, color: SIMD4<Float>(1.0, 0.8, 0.0, 1.0)) {
                batches.append(slicedBatch)
            }
            if let markerPoint = Demo.interpolatedPoint(toolpathPoints, at: scrubIndex),
               let marker = previewDemo.markerBatch(at: markerPoint,
                                                    diameter: Float(activeTool.diameter),
                                                    height: Float(activeTool.fluteLength)) {
                batches.append(marker)
            }
        }
        renderBatches = batches
    }
}
