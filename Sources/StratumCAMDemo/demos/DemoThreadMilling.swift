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

    /// Thread-mills the inside of a pre-drilled M3 pilot hole (2.5mm, the standard
    /// tap-drill size for M3x0.5), a standard right-hand thread -- winds CCW as it
    /// climbs. Mirrors "A right-hand thread on an internal hole winds CCW as it
    /// climbs".
    func demoM3Internal() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .threadMill, diameter: 2.4, fluteLength: 9)
        let cutting = SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 3.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)
        let operation: SC.MachiningOperation = .threadMilling(pitch: 0.5, isInternal: true, direction: .rightHand, radialPasses: 3, targetDiameter: 3.0)

        let contour = circleContour(center: (0, 0), diameter: 2.5)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    // MARK: - External threading (a turned boss)

    /// Thread-mills the outside of a boss, a standard right-hand thread -- also
    /// winds CCW as it climbs, since handedness doesn't flip between internal and
    /// external threads. Mirrors "A right-hand thread on an external boss also
    /// winds CCW -- handedness doesn't flip with isInternal".
    func demoM3External() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .threadMill, diameter: 2.4, fluteLength: 9)
        let cutting = SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 3.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)
        let operation: SC.MachiningOperation = .threadMilling(pitch: 0.5, isInternal: false, direction: .rightHand, radialPasses: 3, targetDiameter: 3.0)

        let contour = circleContour(center: (0, 0), diameter: 3.0)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Multiple holes

    /// Thread-mills four independent hole contours laid out as a rectangle.
    /// Mirrors "threadMilling a batch of holes assigns each toolpath to its own
    /// hole location": each hole gets its own thread-milling toolpath, all
    /// sharing the same tool, settings, pitch, and direction.
    func demoMultipleM3s() -> Demo.DemoResult {
        let tool = SC.ToolParams(type: .threadMill, diameter: 2.4, fluteLength: 9)
        let cutting = SC.CuttingData(feedRate: 900.0, plungeRate: 200.0, stepdown: 3.0)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let centers: [(Double, Double)] = [(0, 0), (10, 0), (20, 0)]
        let contours = centers.map { circleContour(center: $0, diameter: 2.5) }

        let operation: SC.MachiningOperation = .threadMilling(pitch: 0.5, isInternal: true, direction: .rightHand, radialPasses: 3, targetDiameter: 3.0)

        return self.run(contours: contours, tool: tool, settings: settings, operation: operation)
    }
}
