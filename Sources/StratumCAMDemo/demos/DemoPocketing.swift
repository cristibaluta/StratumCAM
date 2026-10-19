//
//  DemoPocketing.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import StratumCAM

class DemoPocketing: Demo {

    // MARK: - Fixtures

    /// A CCW rectangle of the given size, matching the fixture shape used by
    /// `Pocket_Tests.swift`.
    private func rectangleContour(width: Double, height: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(width, 0)), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(width, 0), b: SIMD2<Double>(width, height)), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(width, height), b: SIMD2<Double>(0, height)), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(0, height), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true)
    }

    /// A CCW rounded rectangle with the given corner radius, matching the
    /// fixture shape used by `Pocket_Tests.swift`.
    private func roundedRectangleContour(width: Double, height: Double, cornerRadius r: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(r, 0), b: SIMD2<Double>(width - r, 0)), reversed: false),
            SC.Contour.Chained(geometry: .arc(center: SIMD2<Double>(width - r, r), radius: r, startDeg: -90, endDeg: 0), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(width, r), b: SIMD2<Double>(width, height - r)), reversed: false),
            SC.Contour.Chained(geometry: .arc(center: SIMD2<Double>(width - r, height - r), radius: r, startDeg: 0, endDeg: 90), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(width - r, height), b: SIMD2<Double>(r, height)), reversed: false),
            SC.Contour.Chained(geometry: .arc(center: SIMD2<Double>(r, height - r), radius: r, startDeg: 90, endDeg: 180), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(0, height - r), b: SIMD2<Double>(0, r)), reversed: false),
            SC.Contour.Chained(geometry: .arc(center: SIMD2<Double>(r, r), radius: r, startDeg: 180, endDeg: 270), reversed: false)
        ], isClosed: true)
    }

    /// A concave "staple" shape: a wide base with a rectangular notch removed from
    /// the top-middle, leaving two upward prongs -- matching the fixture in
    /// `Raster_Tests.swift`'s concave-row regression test. Scales the 20x10/notch
    /// 8-12x4-10 test fixture by `scale` so it reads clearly at demo tool sizes.
    private func staplePolygonContour(scale: Double = 2.0) -> SC.Contour {
        let s = scale
        return SC.Contour(entities: [
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(20 * s, 0)), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(20 * s, 0), b: SIMD2<Double>(20 * s, 10 * s)), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(20 * s, 10 * s), b: SIMD2<Double>(12 * s, 10 * s)), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(12 * s, 10 * s), b: SIMD2<Double>(12 * s, 4 * s)), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(12 * s, 4 * s), b: SIMD2<Double>(8 * s, 4 * s)), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(8 * s, 4 * s), b: SIMD2<Double>(8 * s, 10 * s)), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(8 * s, 10 * s), b: SIMD2<Double>(0, 10 * s)), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(0, 10 * s), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true)
    }

    /// A circle of the given radius centered at the origin -- the one boundary shape
    /// `.spiral` treats as eligible for a genuinely continuous spiral (matches how a
    /// DXF `.circle` entity linearizes: two 180° arcs of matching center/radius).
    private func circleContour(radius: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(geometry: .circle(center: SIMD2<Double>(0, 0), radius: radius), reversed: false)
        ], isClosed: true)
    }

    /// A heart, about 40 wide, as a closed polyline of 96 vertices: an irregular shape with a
    /// notch, two lobes and a point.
    private func heartContour(scale: Double = 1.25) -> SC.Contour {
        let count = 96
        var vertices: [SC.Geometry.Vertex] = []
        for i in 0..<count {
            let t = 2 * Double.pi * Double(i) / Double(count)
            let x = 16 * pow(sin(t), 3)
            let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
            vertices.append(SC.Geometry.Vertex(SIMD2<Double>(20 + x * scale, 18 + y * scale)))
        }
        return SC.Contour(entities: [
            SC.Contour.Chained(geometry: .polyline(vertices: vertices, closed: true), reversed: false)
        ], isClosed: true)
    }

    // MARK: - Concentric ring pocketing (Step 2.2)

    /// Clears a 40x24 rectangle with a 6mm tool at 40% stepover. Wide enough
    /// relative to the tool that the ring stack steps inward several times
    /// before the last ring would invert -- makes the concentric stepping
    /// from Step 2.2 actually visible, rather than the single-ring case
    /// Step 2.1's demo would show.
    func demoPocketRectangle() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .offset, entry: .plunge)

        let contour = rectangleContour(width: 40, height: 24)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Same pocket as above but conventional direction, so the ring stack's
    /// start corner and travel direction can be compared side by side with
    /// `demoPocketRectangle()`.
    func demoPocketRectangleConventional() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .conventional, pattern: .offset, entry: .plunge)

        let contour = rectangleContour(width: 40, height: 24)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Climb-milled 40x24 rectangle cleared with closed concentric passes, starting at
    /// the centre and stepping outward one stepover at a time, finishing with the wall
    /// pass. No spiral: every pass is a closed loop.
    func demoPocketRectangleConcentricFromCenter() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .concentric(direction: .insideOut), entry: .plunge)

        let contour = rectangleContour(width: 40, height: 24)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    func demoPocketRectangleConcentricFromCenterRampEntry() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .concentric(direction: .insideOut), entry: .ramp(angleDegrees: 3.0))

        let contour = rectangleContour(width: 40, height: 24)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// A heart cleared with concentric passes from the centre: circles grow from the point
    /// furthest from the wall, and once they reach the wall they keep growing, moulding onto
    /// the heart's outline, until the last pass is the wall itself.
    func demoPocketHeartConcentricFromCenter() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .concentric(direction: .insideOut), entry: .plunge)
        return self.run(contour: heartContour(), tool: tool, settings: settings, operation: operation)
    }

    /// The same climb-milled, centre-out 40x24 pocket as
    /// `demoPocketRectangleConcentricFromCenter()`, with a few pseudo-random round islands
    /// left standing. Rings that meet an island follow its edge instead of cutting
    /// through it, and each island wall is finished with its own loop at the end.
    func demoPocketRectangleConcentricWithIslands() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .concentric(direction: .insideOut), entry: .plunge)

        var contour = rectangleContour(width: 40, height: 24)
        contour.islands = randomCircleIslands(count: 3,
                                              seed: 7,
                                              toolRadius: tool.diameter / 2.0,
                                              width: 40,
                                              height: 24)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Same pocket and islands as `demoPocketRectangleConcentricWithIslands()`, but the
    /// islands are not attached to the pocket: the pocket outline and the circles are
    /// passed as one flat list of shapes and the engine detects which sit inside which.
    func demoPocketRectangleConcentricAutoIslands() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .concentric(direction: .insideOut), entry: .plunge)

        let shapes = [rectangleContour(width: 40, height: 24)]
            + randomCircleIslands(count: 3, seed: 7, toolRadius: tool.diameter / 2.0, width: 40, height: 24)
        return self.run(contours: shapes, tool: tool, settings: settings, operation: operation)
    }

    /// A 60x36 pocket with a rectangular island and a triangular one, passed as plain
    /// shapes in one flat list. Islands don't have to be circles: any closed outline
    /// inside the pocket is detected and left standing.
    func demoPocketRectangleConcentricShapedIslands() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .concentric(direction: .insideOut), entry: .plunge)

        let block = SC.Contour(entities: [
            SC.Contour.Chained(geometry: .polyline(vertices: [SC.Geometry.Vertex(SIMD2<Double>(10, 12)),
                                                              SC.Geometry.Vertex(SIMD2<Double>(22, 12)),
                                                              SC.Geometry.Vertex(SIMD2<Double>(22, 24)),
                                                              SC.Geometry.Vertex(SIMD2<Double>(10, 24))],
                                                     closed: true), reversed: false)
        ], isClosed: true)
        let triangle = SC.Contour(entities: [
            SC.Contour.Chained(geometry: .polyline(vertices: [SC.Geometry.Vertex(SIMD2<Double>(36, 10)),
                                                              SC.Geometry.Vertex(SIMD2<Double>(48, 10)),
                                                              SC.Geometry.Vertex(SIMD2<Double>(42, 22))],
                                                     closed: true), reversed: false)
        ], isClosed: true)

        return self.run(contours: [rectangleContour(width: 60, height: 36), block, triangle],
                        tool: tool,
                        settings: settings,
                        operation: operation)
    }

    /// The 60x36 pocket with a rectangular and a triangular island from
    /// `demoPocketRectangleConcentricShapedIslandsRamp()`, entered with a 3 degree ramp that
    /// follows the toolpath (circular moves stay circular in XY) instead of plunging.
    func demoPocketRectangleConcentricShapedIslandsRamp() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .concentric(direction: .insideOut), entry: .ramp(angleDegrees: 3.0))

        let block = SC.Contour(entities: [
            SC.Contour.Chained(geometry: .polyline(vertices: [SC.Geometry.Vertex(SIMD2<Double>(10, 12)),
                                                              SC.Geometry.Vertex(SIMD2<Double>(22, 12)),
                                                              SC.Geometry.Vertex(SIMD2<Double>(22, 24)),
                                                              SC.Geometry.Vertex(SIMD2<Double>(10, 24))],
                                                     closed: true), reversed: false)
        ], isClosed: true)
        let triangle = SC.Contour(entities: [
            SC.Contour.Chained(geometry: .polyline(vertices: [SC.Geometry.Vertex(SIMD2<Double>(36, 10)),
                                                              SC.Geometry.Vertex(SIMD2<Double>(48, 10)),
                                                              SC.Geometry.Vertex(SIMD2<Double>(42, 22))],
                                                     closed: true), reversed: false)
        ], isClosed: true)

        return self.run(contours: [rectangleContour(width: 60, height: 36), block, triangle],
                        tool: tool,
                        settings: settings,
                        operation: operation)
    }

    /// Deterministic pseudo-random circular islands inside a `width` x `height` pocket
    /// whose lower-left corner is the origin. Each island keeps clear of the walls, of
    /// the other islands (by at least the tool diameter... the tool must fit between
    /// them) and of the pocket centre, where the centre-out passes begin.
    private func randomCircleIslands(count: Int, seed: UInt64, toolRadius: Double, width: Double, height: Double) -> [SC.Contour] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }

        var placed: [(x: Double, y: Double, radius: Double)] = []
        var attempts = 0
        while placed.count < count && attempts < 500 {
            attempts += 1
            let radius = 1.5 + next() * 1.5
            let zone = radius + toolRadius
            // Tool-centre wall ring is inset by the tool radius; keep the whole zone inside it.
            let margin = toolRadius + zone + 0.5
            guard width > 2 * margin, height > 2 * margin else {
                continue
            }
            let x = margin + next() * (width - 2 * margin)
            let y = margin + next() * (height - 2 * margin)

            guard hypot(x - width / 2, y - height / 2) > zone + toolRadius + 2 else {
                continue
            }
            let clear = placed.allSatisfy { other in
                hypot(x - other.x, y - other.y) > zone + (other.radius + toolRadius) + 1
            }
            if clear {
                placed.append((x, y, radius))
            }
        }

        return placed.map { island in
            SC.Contour(entities: [
                SC.Contour.Chained(geometry: .circle(center: SIMD2<Double>(island.x, island.y), radius: island.radius), reversed: false)
            ], isClosed: true)
        }
    }

    /// Clears a rounded rectangle, showing the ring stack's corner arcs shrinking
    /// ring by ring until the corner radius collapses to a sharp point -- at which
    /// point that corner just becomes a plain rectangle corner and stepping keeps
    /// going on the straight edges, same as `demoPocketRectangle()`, until *those*
    /// invert (the winding-flip signal both demos ultimately rely on).
    func demoPocketRoundedRectangle() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.3)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -2.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .offset, entry: .plunge)

        let contour = roundedRectangleContour(width: 40, height: 24, cornerRadius: 5)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Multi-pass Z stepdown (Step 1.3)
    // Mirrors the fixtures in PocketZPasses_Tests.swift so each demo below reproduces
    // the exact scenario a corresponding unit test asserts on: a 20x10 rectangle, same
    // as `ccwRectangleContour()` there.

    /// Clears the 20x10 rectangle across 3 Z passes (-1.0, -2.0, -2.5) with a plain
    /// plunge entry. Mirrors "Pocket honors calculateZPasses for an unevenly divisible
    /// depth" and "Pocket plunge entry is unaffected by multi-pass Z stepdown": the
    /// single ring is retraced at each of the 3 depths, plunging fresh from safeZ every
    /// time rather than threading `previousZ` (that's only a `.ramp`/`.helix` concern --
    /// see `demoRampEntryMultiPass()`/`demoHelixEntryMultiPass()` below).
    func demoMultiPassZStepdown() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -2.5)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .offset, entry: .plunge)

        let contour = rectangleContour(width: 20, height: 10)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Same rectangle and Z stepdown as `demoMultiPassZStepdown()`, but `.raster`
    /// instead of `.offsetPattern`. Mirrors "Raster pocket also gets multi-pass Z
    /// stepdown, not just offsetPattern": the same scanline rows get retraced at
    /// -1.0 then -2.0, proving Step 1.3 isn't wired to only one pattern type.
    func demoRasterMultiPassZStepdown() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -2.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .raster, entry: .plunge)

        let contour = rectangleContour(width: 20, height: 10)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// A smaller 4mm tool at 50% stepover produces 2 concentric rings; this clears
    /// them across 2 Z passes (-1.0, -2.0). Mirrors "Pocket ring geometry is computed
    /// once and reused unchanged across every Z pass": in the 3D preview the two
    /// rings should look identical when viewed from directly above at either depth --
    /// only the Z of the trace changes, not the XY shape.
    func demoRingGeometryReusedAcrossPasses() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 4.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -2.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .offset, entry: .plunge)

        let contour = rectangleContour(width: 20, height: 10)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Ramp entry across 2 Z passes (-1.0, -2.0). Mirrors "Pocket ramp entry on a
    /// later pass starts from the previous pass's depth, not top-of-stock": the first
    /// pass's ramp zig-zags through the fresh 0 -> -1.0 stepdown, and the second
    /// pass's ramp only covers the fresh -1.0 -> -2.0 stepdown -- in the preview the
    /// second ramp should look like a short repeat of the first, not a ramp twice as
    /// long re-covering ground the first pass already opened up.
    func demoRampEntryMultiPass() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -2.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .offset, entry: .ramp(angleDegrees: 30))

        let contour = rectangleContour(width: 20, height: 10)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Helix entry across 2 Z passes (-1.0, -2.0). Mirrors "Pocket helix entry on a
    /// later pass only spirals through its own fresh stepdown": the second pass's
    /// spiral should stay entirely between -1.0 and -2.0 in the preview, never
    /// climbing back up through the depths the first pass already cleared.
    func demoHelixEntryMultiPass() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -2.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .offset, entry: .helix(radius: 1.0, rampAngleDegrees: 30))

        let contour = rectangleContour(width: 20, height: 10)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Circular pocket (radius 20) cleared inside-out with concentric circles and a helix
    /// entry. The helix is centered on the circle's center (not to the side): it spirals
    /// down at the first ring's radius, ends back at its start angle, and the first ring
    /// is the flat full circle that cleans the sloped floor, then the rings grow outward.
    /// Two Z passes, so the second helix only spans its own fresh stepdown.
    func demoHelixEntryCircle() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -2.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb,
                                                       pattern: .concentric(direction: .insideOut),
                                                       entry: .helix(radius: 3.0, rampAngleDegrees: 3.0))

        let contour = circleContour(radius: 20)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Raster clearing (Step 1.1)

    /// Clears a 40x24 rectangle with parallel scanline rows instead of concentric
    /// rings -- the direct visual contrast with `demoPocketRectangle()`'s ring
    /// stack, both clearing the identical rectangle with the identical tool.
    func demoRasterRectangle() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .raster, entry: .plunge)

        let contour = rectangleContour(width: 40, height: 24)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Same raster clearing as above but conventional direction, so the first
    /// row's start corner and sweep direction can be compared side by side with
    /// `demoRasterRectangle()`.
    func demoRasterRectangleConventional() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .conventional, pattern: .raster, entry: .plunge)

        let contour = rectangleContour(width: 40, height: 24)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Clears a rounded rectangle with scanlines, showing rows clip against the
    /// true corner-arc sweep -- the bottom/top rows narrow inward at the rounded
    /// corners instead of squaring off at the plain bounding box, same behavior
    /// `Raster_Tests.testRasterClipsAgainstRoundedContour` locks in.
    func demoRasterRoundedRectangle() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.3)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -2.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .raster, entry: .plunge)

        let contour = roundedRectangleContour(width: 40, height: 24, cornerRadius: 5)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Raster clearing with a ramp entry into the first row -- mirrors
    /// `demoRampEntryMultiPass()` but for `.raster` instead of `.offsetPattern`,
    /// proving Step 1.2's entry integration isn't wired to only one pattern type.
    func demoRasterRampEntry() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .raster, entry: .ramp(angleDegrees: 30))

        let contour = rectangleContour(width: 40, height: 24)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Raster clearing with a helix entry into the first row -- same pairing as
    /// `demoRasterRampEntry()`, for the other non-plunge entry style.
    func demoRasterHelixEntry() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .raster, entry: .helix(radius: 2.0, rampAngleDegrees: 30))

        let contour = rectangleContour(width: 40, height: 24)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Clears a concave "staple" shape (two prongs joined by a wide base) with
    /// scanlines. Visualizes the fix for a real bug found while extending Step 1.4's
    /// test coverage: rows crossing the notch used to bridge straight across the empty
    /// gap between the prongs as one long (wrong) cut; `rasterScanlines` now skips any
    /// row that re-enters the boundary more than once instead, per its own doc comment
    /// -- so in this preview, only the rows below the notch are cut, and the two prongs
    /// above it are left untouched by the raster pass. See
    /// `Raster_Tests.testRasterSkipsConcaveReentrantRows`.
    func demoRasterConcaveStapleSkipsBridgingRows() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 4.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .raster, entry: .plunge)

        let contour = staplePolygonContour(scale: 2.0)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Spiral clearing (Step 1B.1)

    /// Clears a 20mm-radius circular pocket with one continuous inward spiral
    /// instead of discrete rings -- the direct visual contrast with
    /// `demoPocketRectangle()`'s ring stack: no lateral "jump" transition between
    /// passes, just one smoothly shrinking curve down to the center.
    func demoSpiralCircle() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .spiral(direction: .outsideIn), entry: .plunge)

        let contour = circleContour(radius: 20)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    func demoSpiralCircleInsideOut() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .spiral(direction: .insideOut), entry: .plunge)

        let contour = circleContour(radius: 20)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// The same 40x24 rectangle and settings as `demoPocketRectangle()`, but with
    /// `.spiral` requested instead of `.offsetPattern`. A rectangle has no single
    /// center to spiral around, so this should look identical to
    /// `demoPocketRectangle()` -- the discrete ring-and-chain fallback `.spiral`
    /// takes on any non-circular boundary, not a spiral computed around the wrong
    /// point. See `isSpiralEligible`.
    func demoSpiralFallbackOnRectangle() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .spiral(direction: .outsideIn), entry: .plunge)

        let contour = rectangleContour(width: 40, height: 24)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Trochoidal clearing (Step 1B.2)

    /// Clears a 40x24 rectangle with a stack of concentric wall-anchored
    /// trochoidal bounces instead of concentric rings or scanlines -- the
    /// direct visual contrast with `demoPocketRectangle()`/
    /// `demoRasterRectangle()`, all three clearing the identical rectangle
    /// with the identical tool. In the preview this reads as a series of
    /// overlapping "D" lobes riding each ring of `pocketRings`'s own stack
    /// (see `ringTrochoidalSegments`'s doc comment), stepping inward band by
    /// band until the whole interior is cleared -- not just a single pass
    /// that stays on the outer wall.
    ///
    /// `radialEngagement` (a fraction of `tool.diameter / 2`, clamped to
    /// `0...1`) sets how far each bounce advances along its own ring before
    /// the next one; `loopRadius` is unused here -- the bounce's own inward
    /// reach is always exactly `stepoverPercentage * tool.diameter` (the same
    /// ring-to-ring spacing `.offsetPattern` uses), not a separately
    /// configurable radius.
    func demoTrochoidalRectangle() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)
        let tro = SC.TrochoidalSettings(radialEngagement: 0.5, loopRadius: 0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .trochoidal(settings: tro), entry: .plunge)

        let contour = rectangleContour(width: 40, height: 24)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Same trochoidal clearing as above but conventional direction, so the
    /// bounce chain's start corner and travel direction can be compared side
    /// by side with `demoTrochoidalRectangle()` -- mirrors
    /// `orientedForDirection`'s reversal the same way
    /// `demoPocketRectangleConventional()`/`demoRasterRectangleConventional()`
    /// already demonstrate for the other two patterns.
    func demoTrochoidalRectangleConventional() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)
        let tro = SC.TrochoidalSettings(radialEngagement: 0.5, loopRadius: 0)

        let operation: SC.MachiningOperation = .pocket(direction: .conventional, pattern: .trochoidal(settings: tro), entry: .plunge)

        let contour = rectangleContour(width: 40, height: 24)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Clears the same 20mm-radius circle `demoSpiralCircle()` uses, but with
    /// a stack of wall-anchored trochoidal bounces instead of a continuous
    /// inward spiral -- unlike `.spiral`, which only produces a true spiral on
    /// this exact circular boundary (falling back to rings otherwise),
    /// `.trochoidal` treats every boundary shape identically: it always
    /// bounces ring by ring via `pocketRings`, whether or not that stack
    /// happens to be circular. Side by side with `demoSpiralCircle()`, this
    /// contrasts "one smoothly shrinking curve down to the center" against "a
    /// stack of overlapping bounces stepping inward band by band."
    func demoTrochoidalCircle() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)
        let tro = SC.TrochoidalSettings(radialEngagement: 0.5, loopRadius: 0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .trochoidal(settings: tro), entry: .plunge)

        let contour = circleContour(radius: 20)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }
}
