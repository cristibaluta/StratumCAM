//
//  MetalCanvasView.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import SwiftUI
import MetalKit

struct MetalCanvasView: NSViewRepresentable {
    @Binding var batches: [RenderBatch]

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        guard let renderer = MetalRenderer(metalView: mtkView) else { return mtkView }
        
        context.coordinator.renderer = renderer
        mtkView.delegate = renderer
        
        // Setup Gesture Recognizers
        let panGesture = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        let clickGesture = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        
        mtkView.addGestureRecognizer(panGesture)
        mtkView.addGestureRecognizer(clickGesture)
        
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.renderer?.updateGeometry(batches: batches)
    }

    class Coordinator: NSObject {
        var parent: MetalCanvasView
        var renderer: MetalRenderer?
        private var lastMousePosition: CGPoint = .zero

        init(_ parent: MetalCanvasView) {
            self.parent = parent
        }

        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard let camera = renderer?.camera else { return }
            let translation = gesture.translation(in: gesture.view)
            
            if NSEvent.modifierFlags.contains(.shift) {
                // Pan Camera (Shift + Drag)
                let scale: Float = 0.05
                camera.target.x -= Float(translation.x) * scale
                camera.target.y -= Float(translation.y) * scale
            } else {
                // Orbit Camera (Drag)
                let sensitivity: Float = 0.005
                camera.rotation.y -= Float(translation.x) * sensitivity
                camera.rotation.x = max(-.pi/2 + 0.1, min(.pi/2 - 0.1, camera.rotation.x + Float(translation.y) * sensitivity))
            }
            gesture.setTranslation(.zero, in: gesture.view)
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            // Optional: Handle selection / Raycasting targeting
        }
    }
}
