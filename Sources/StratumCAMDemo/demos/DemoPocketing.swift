//
//  DemoPocketing.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import StratumCAM
import SwiftDXF

class DemoPocketing: Demo {

    // MARK: - Fixtures

    /// A CCW rectangle of the given size, matching the fixture shape used by
    /// `Pocket_Tests.swift`.
    private func rectangleContour(width: Double, height: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(width, 0), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(width, 0), b: DXF.Point(width, height), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(width, height), b: DXF.Point(0, height), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(0, height), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)
    }

    /// A CCW rounded rectangle with the given corner radius, matching the
    /// fixture shape used by `Pocket_Tests.swift`.
    private func roundedRectangleContour(width: Double, height: Double, cornerRadius r: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(entity: .line(a: DXF.Point(r, 0), b: DXF.Point(width - r, 0), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .arc(center: DXF.Point(width - r, r), radius: r, startDeg: -90, endDeg: 0, layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(width, r), b: DXF.Point(width, height - r), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .arc(center: DXF.Point(width - r, height - r), radius: r, startDeg: 0, endDeg: 90, layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(width - r, height), b: DXF.Point(r, height), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .arc(center: DXF.Point(r, height - r), radius: r, startDeg: 90, endDeg: 180, layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .line(a: DXF.Point(0, height - r), b: DXF.Point(0, r), layer: "0", color: 7), reversed: false),
            SC.Contour.Chained(entity: .arc(center: DXF.Point(r, r), radius: r, startDeg: 180, endDeg: 270, layer: "0", color: 7), reversed: false)
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
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .offsetPattern, entry: .plunge)

        return self.run(contour: rectangleContour(width: 40, height: 24), tool: tool, settings: settings, operation: operation)
    }

    /// Same pocket as above but conventional direction, so the ring stack's
    /// start corner and travel direction can be compared side by side with
    /// `demoPocketRectangle()`.
    func demoPocketRectangleConventional() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4), safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .conventional, pattern: .offsetPattern, entry: .plunge)

        return self.run(contour: rectangleContour(width: 40, height: 24), tool: tool, settings: settings, operation: operation)
    }

    /// Clears a rounded rectangle, showing the ring stack's corner arcs
    /// shrinking ring by ring until the corner radius collapses and stepping
    /// stops -- the arc-collapse signal `pocketRings` relies on, rather than
    /// the straight-edge winding-flip signal `demoPocketRectangle()` hits.
    func demoPocketRoundedRectangle() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.3), safeZ: 5.0, targetDepth: -2.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .offsetPattern, entry: .plunge)

        return self.run(contour: roundedRectangleContour(width: 40, height: 24, cornerRadius: 5), tool: tool, settings: settings, operation: operation)
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
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.5)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .offsetPattern, entry: .plunge)

        return self.run(contour: rectangleContour(width: 20, height: 10), tool: tool, settings: settings, operation: operation)
    }

    /// Same rectangle and Z stepdown as `demoMultiPassZStepdown()`, but `.raster`
    /// instead of `.offsetPattern`. Mirrors "Raster pocket also gets multi-pass Z
    /// stepdown, not just offsetPattern": the same scanline rows get retraced at
    /// -1.0 then -2.0, proving Step 1.3 isn't wired to only one pattern type.
    func demoRasterMultiPassZStepdown() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5), safeZ: 5.0, targetDepth: -2.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .raster, entry: .plunge)

        return self.run(contour: rectangleContour(width: 20, height: 10), tool: tool, settings: settings, operation: operation)
    }

    /// A smaller 4mm tool at 50% stepover produces 2 concentric rings; this clears
    /// them across 2 Z passes (-1.0, -2.0). Mirrors "Pocket ring geometry is computed
    /// once and reused unchanged across every Z pass": in the 3D preview the two
    /// rings should look identical when viewed from directly above at either depth --
    /// only the Z of the trace changes, not the XY shape.
    func demoRingGeometryReusedAcrossPasses() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 4.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.5), safeZ: 5.0, targetDepth: -2.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .offsetPattern, entry: .plunge)

        return self.run(contour: rectangleContour(width: 20, height: 10), tool: tool, settings: settings, operation: operation)
    }

    /// Ramp entry across 2 Z passes (-1.0, -2.0). Mirrors "Pocket ramp entry on a
    /// later pass starts from the previous pass's depth, not top-of-stock": the first
    /// pass's ramp zig-zags through the fresh 0 -> -1.0 stepdown, and the second
    /// pass's ramp only covers the fresh -1.0 -> -2.0 stepdown -- in the preview the
    /// second ramp should look like a short repeat of the first, not a ramp twice as
    /// long re-covering ground the first pass already opened up.
    func demoRampEntryMultiPass() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .offsetPattern, entry: .ramp(angleDegrees: 30))

        return self.run(contour: rectangleContour(width: 20, height: 10), tool: tool, settings: settings, operation: operation)
    }

    /// Helix entry across 2 Z passes (-1.0, -2.0). Mirrors "Pocket helix entry on a
    /// later pass only spirals through its own fresh stepdown": the second pass's
    /// spiral should stay entirely between -1.0 and -2.0 in the preview, never
    /// climbing back up through the depths the first pass already cleared.
    func demoHelixEntryMultiPass() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0), safeZ: 5.0, targetDepth: -2.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .offsetPattern, entry: .helix(radius: 1.0, rampAngleDegrees: 30))

        return self.run(contour: rectangleContour(width: 20, height: 10), tool: tool, settings: settings, operation: operation)
    }
}
