//
//  DemothreadMilling.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation
import StratumCAM
import SwiftDXF

class DemoThreadMilling: Demo {

    // MARK: - Fixtures
    // Mirrors the fixtures in threadMilling_Tests.swift so each demo below reproduces
    // the exact scenario a corresponding unit test asserts on.

    /// A closed circle contour marking a hole (internal thread) or boss
    /// (external thread) of `diameter`, centered at `center` -- the same
    /// "closed circle marks the feature" shape `tapCircle(for:)` recognizes.
    private func circleContour(center: (Double, Double), diameter: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(entity: .circle(center: DXF.Point(center.0, center.1),
                                               radius: diameter / 2.0,
                                               layer: "0",
                                               color: 7),
                               reversed: false)
        ], isClosed: true)
    }

    // MARK: - Internal threading (a pre-drilled hole)

    /// Thread-mills the inside of a hole, climb milling -- winds CW, same
    /// convention an `.inside` wall cut uses. Mirrors "Internal threading
    /// milled climb winds CW, the same as an .inside wall cut".
    func demoM3() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .threadMill, diameter: 2.5)
        let cutting = SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 5.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -5.0)
        let operation: SC.MachiningOperation = .threadMilling(pitch: 0.5, isInternal: true, direction: .climb, radialPasses: 3)

        return self.run(contour: circleContour(center: (0, 0), diameter: 3.0), tool: tool, settings: settings, operation: operation)
    }

    /// Same hole, conventional milling -- winds CCW instead. Mirrors "Internal
    /// threading milled conventional winds CCW, the same as an .inside wall cut".
    func demoInternalConventional() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let cutting = SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .threadMilling(pitch: 1.0, isInternal: true, direction: .conventional, radialPasses: 3)

        return self.run(contour: circleContour(center: (0, 0), diameter: 10.0), tool: tool, settings: settings, operation: operation)
    }

    // MARK: - External threading (a turned boss)

    /// Thread-mills the outside of a boss, climb milling -- winds CCW, same
    /// convention an `.outside` wall cut uses. Mirrors "External threading
    /// milled climb winds CCW, the same as an .outside cut".
    func demoExternalClimb() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0)
        let cutting = SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -2.0)

        let operation: SC.MachiningOperation = .threadMilling(pitch: 2.0, isInternal: false, direction: .climb, radialPasses: 3)

        return self.run(contour: circleContour(center: (10, 20), diameter: 12.0), tool: tool, settings: settings, operation: operation)
    }

    /// Same boss, conventional milling -- winds CW instead. Mirrors "External
    /// threading milled conventional winds CW, the same as an .outside cut".
    func demoExternalConventional() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 4.0)
        let cutting = SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -2.0)

        let operation: SC.MachiningOperation = .threadMilling(pitch: 2.0, isInternal: false, direction: .conventional, radialPasses: 3)

        return self.run(contour: circleContour(center: (10, 20), diameter: 12.0), tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Deep, multi-turn thread

    /// A deep internal thread that needs several full revolutions to reach
    /// target depth -- makes the per-revolution `pitch` stepdown and the
    /// final closing lap visually obvious in the preview, unlike the
    /// single/short-turn demos above.
    func demoDeepMultiTurnThread() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let cutting = SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -10.0)

        let operation: SC.MachiningOperation = .threadMilling(pitch: 1.5, isInternal: true, direction: .climb, radialPasses: 3)

        return self.run(contour: circleContour(center: (0, 0), diameter: 14.0), tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Multiple holes

    /// Thread-mills four independent hole contours laid out as a rectangle.
    /// Mirrors "threadMilling a batch of holes assigns each toolpath to its own
    /// hole location": each hole gets its own thread-milling toolpath, all
    /// sharing the same tool, settings, pitch, and direction.
    func demoMultipleHoles() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 3.0)
        let cutting = SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 1.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -2.0)

        let centers: [(Double, Double)] = [(0, 0), (20, 0), (20, 20), (0, 20)]
        let contours = centers.map { circleContour(center: $0, diameter: 10.0) }

        let operation: SC.MachiningOperation = .threadMilling(pitch: 1.0, isInternal: true, direction: .climb, radialPasses: 3)

        return self.run(contours: contours, tool: tool, settings: settings, operation: operation)
    }
}
