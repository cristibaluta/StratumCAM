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

    /// Step 5.4: the currently-shown demo's raw toolpath points (Step 5.1), kept
    /// around so the scrub slider below has something to slice through, and the
    /// slider's own position -- a `Double` (not `Int`) already, ahead of Step 5.5's
    /// interpolation, ranged over `0...Double(max(0, toolpathPoints.count - 1))`.
    @State private var toolpathPoints: [SIMD3<Float>] = []
    @State private var scrubIndex: Double = 0

    /// The part of the current demo's `renderBatches` that *isn't* the toolpath --
    /// the blue base-contour batch, currently, though this doesn't assume there's
    /// exactly one. Kept separate from `renderBatches` so `rebuildRenderBatches()`
    /// can recompute just the sliced-toolpath + marker batches on every scrub
    /// change without re-running the whole demo.
    @State private var staticBatches: [RenderBatch] = []

    /// Used only to build the sliced-prefix/marker batches below -- a plain `Demo`
    /// (not a `DemoEngraving`/`DemoPocketing` subclass) works fine since
    /// `pointsPrefix`/`renderBatch`/`markerBatch` don't touch any demo-specific
    /// fixtures, just `device`.
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
                    // Step 5.4: scrub slider lives in the same corner as the orbit/pan
                    // hint, stacked above it, since both are canvas-control chrome.
                    // Hidden entirely when the current demo has no toolpath points at
                    // all (shouldn't happen for any demo today, but `pointsPrefix`
                    // already handles an empty array safely if it ever does).
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

    /// Called whenever a sidebar demo button fires. Stores the new demo's raw
    /// toolpath points (Step 5.1) and resets `scrubIndex` to the *last* index so
    /// switching demos always starts fully drawn, rather than at a stale scrub
    /// position left over from whatever was previously selected.
    private func show(_ result: Demo.DemoResult) {
        gcodeText = result.gcode
        toolpathPoints = result.toolpathPoints

        // The full toolpath batch is always the last one `run(contours:...)`
        // appends whenever `toolpathPoints` is non-empty (step 4 there) -- everything
        // before it (the blue base-contour batch, today) is scrub-independent and
        // gets reused as-is by every `rebuildRenderBatches()` call below.
        staticBatches = toolpathPoints.isEmpty ? result.batches : Array(result.batches.dropLast())

        scrubIndex = Double(max(0, toolpathPoints.count - 1))
        rebuildRenderBatches()
    }

    /// Step 5.4: rebuilds `renderBatches` as `[contour batch, sliced toolpath batch
    /// (5.2), marker batch (5.3)]` from the current `scrubIndex` -- called once from
    /// `show(_:)` after a new demo loads, and again on every slider change.
    private func rebuildRenderBatches() {
        var batches = staticBatches
        if !toolpathPoints.isEmpty {
            let index = Int(scrubIndex.rounded())
            let prefix = Demo.pointsPrefix(toolpathPoints, upTo: index)

            if let slicedBatch = previewDemo.renderBatch(forPoints: prefix, color: SIMD4<Float>(1.0, 0.8, 0.0, 1.0)) {
                batches.append(slicedBatch)
            }
            if let lastPoint = prefix.last, let marker = previewDemo.markerBatch(at: lastPoint) {
                batches.append(marker)
            }
        }
        renderBatches = batches
    }
}
