# StratumCAM Visual Test Harness Plan

## Step 1: Geometry Data Pipeline & SIMD Conversion
- [ ] Implement a lightweight inline DXF-to-SCContour hardcoded parser or mock loader (Lines, Arcs, Polylines).
- [ ] Create a converter utility: `SCContour` / `SCSegment` -> `[SIMD3<Float>]` vertex buffers for Metal.
- [ ] Add arc tessellation logic with configurable tolerance to convert circular arcs into linear SIMD segments.

## Step 2: MetalKit 3D Render Canvas Setup
- [ ] Set up `MTKView` and `MTKViewDelegate` in SwiftUI using `NSViewRepresentable`.
- [ ] Implement simple 3D shaders (`position` + `color`) for line rendering (`MTLPrimitiveType.lineStrip` / `.line`).
- [ ] Implement camera controls: Pan, Zoom (Scroll wheel), and Orbit/Rotate (Mouse Drag) via SIMD transformation matrices.
- [ ] Add visual overlays:
  - **Stock / Boundary**: Gray wireframe box or outline.
  - **Raw Input CAD Geometry**: White / Bright Cyan vector overlay.
  - **Generated Toolpath Passes**: Color-coded paths (e.g., Red = Rapid G0, Blue = Cut G1, Green = Lead-In/Out).

## Step 3: Test Suite Integration & Sidebar App UX
- [ ] Build a Navigation Split View UX:
  - **Sidebar**: List of Test Cases grouped by Feature/Strategy.
  - **Main View**: Metal 3D Canvas + Toolpath parameter controls overlay panel (Tool Diameter, Pass Depth, Stepover).
- [ ] Implement hardcoded Test Cases:
  - **Test Case 1: Primitive Geometry**: Direct Line, Arc, and Closed Circle tessellation verification.
  - **Test Case 2: Profiling Strategy**:
    - Outer Contour with Tool Offset (Left/Right).
    - Lead-In / Lead-Out arc/tangent entries.
  - **Test Case 3: Pocketing Strategy**:
    - Rectangular and Irregular shape clearing.
    - Stepover visualization (Zig-Zag vs Offset Spiral).
  - **Test Case 4: Chamfering**:
    - 3D chamfer path positioning with conical tool profile offset.
  - **Test Case 5: Drilling Operations**:
    - Point matrix and peck drilling Z-retract movements.
  - **Test Case 6: Multi-Pass Z-Depth**:
    - Multiple Z-level step-downs for deep cuts.

## Step 4: Verification & Interactive Visual Overlay
- [ ] Add depth offset / layer toggles in the view to isolate geometry layer vs toolpath layer.
- [ ] Add animation slider to simulate tool movement along the generated `SCMotionType` array step-by-step.