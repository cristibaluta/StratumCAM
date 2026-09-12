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
}
