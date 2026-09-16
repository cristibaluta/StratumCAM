//
//  DemoContour.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import StratumCAM
import SwiftDXF

class DemoContour: Demo {

    // MARK: - Fixtures
    // Mirrors the fixtures in Profile_Tests.swift so each demo below reproduces
    // the exact scenario a corresponding unit test asserts on.

    /// A 10x10 CCW square: (0,0) -> (10,0) -> (10,10) -> (0,10) -> back to (0,0).
    private func ccwSquareContour() -> SC.Contour {
        SC.Contour(
            entities: [
                SC.Contour.Chained(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false),
                SC.Contour.Chained(entity: .line(a: DXF.Point(10, 0), b: DXF.Point(10, 10), layer: "0", color: 7), reversed: false),
                SC.Contour.Chained(entity: .line(a: DXF.Point(10, 10), b: DXF.Point(0, 10), layer: "0", color: 7), reversed: false),
                SC.Contour.Chained(entity: .line(a: DXF.Point(0, 10), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
            ],
            isClosed: true
        )
    }

    private func ccwRectangleContour(width: Double, height: Double) -> SC.Contour {
        SC.Contour(
            entities: [
                SC.Contour.Chained(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(width, 0), layer: "0", color: 7), reversed: false),
                SC.Contour.Chained(entity: .line(a: DXF.Point(width, 0), b: DXF.Point(width, height), layer: "0", color: 7), reversed: false),
                SC.Contour.Chained(entity: .line(a: DXF.Point(width, height), b: DXF.Point(0, height), layer: "0", color: 7), reversed: false),
                SC.Contour.Chained(entity: .line(a: DXF.Point(0, height), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
            ],
            isClosed: true
        )
    }

    /// A 20mm-long line split into 4 equal segments, so a tab centered mid-path
    /// lands exactly on a vertex instead of the middle of a single segment.
    private func fourSegmentLineContour() -> SC.Contour {
        SC.Contour(
            entities: [
                SC.Contour.Chained(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(5, 0), layer: "0", color: 7), reversed: false),
                SC.Contour.Chained(entity: .line(a: DXF.Point(5, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false),
                SC.Contour.Chained(entity: .line(a: DXF.Point(10, 0), b: DXF.Point(15, 0), layer: "0", color: 7), reversed: false),
                SC.Contour.Chained(entity: .line(a: DXF.Point(15, 0), b: DXF.Point(20, 0), layer: "0", color: 7), reversed: false)
            ],
            isClosed: false
        )
    }

    // MARK: - Offset direction

    /// Profiles the outside wall of the square, climb-milling with a plain
    /// plunge entry. Mirrors "Outside profile offsets the toolpath away from
    /// the contour": with a 6mm tool the offset toolpath expands the square's
    /// bounding box out from [0, 10] to [-3, 13] on both axes. Also covers
    /// "Plunge entry starts directly on the offset contour's start point",
    /// since that test uses this exact configuration.
    func demoOutsideSquare() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 0.1)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .contour(side: .outside,
                                                        direction: .climb,
                                                        entry: .plunge,
                                                        leadIn: nil,
                                                        leadOut: nil,
                                                        tabs: [])

        let contour = ccwSquareContour()
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Profiles the inside wall of the square. Mirrors "Inside profile offsets
    /// the toolpath toward the contour center": with a 6mm tool the toolpath
    /// shrinks the square's bounding box in from [0, 10] to [3, 7] on both axes.
    func demoInsideSquare() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 0.1)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .contour(side: .inside,
                                                        direction: .climb,
                                                        entry: .plunge,
                                                        leadIn: nil,
                                                        leadOut: nil,
                                                        tabs: [])

        let contour = ccwSquareContour()
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Entry strategies

    /// Enters the outside profile with a shallow ramp instead of a straight
    /// plunge. Mirrors "Ramp entry descends gradually and lands back on the
    /// contour start at depth": the tool zig-zags across the top edge, dropping
    /// partway on the way out and landing exactly at target depth on the way back.
    func demoRampEntry() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 0.1)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .contour(side: .outside,
                                                        direction: .climb,
                                                        entry: .ramp(angleDegrees: 3),
                                                        leadIn: nil,
                                                        leadOut: nil,
                                                        tabs: [])

        let contour = ccwSquareContour()
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Enters the outside profile by spiraling down. Mirrors "Helix entry
    /// spirals down and returns to the contour start at depth": the tool
    /// corkscrews at the start point until it completes a whole number of
    /// turns and lands back on the contour start, exactly at target depth.
    func demoHelixEntry() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 0.1)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .contour(side: .outside,
                                                        direction: .climb,
                                                        entry: .helix(radius: 2, rampAngleDegrees: 3),
                                                        leadIn: nil,
                                                        leadOut: nil,
                                                        tabs: [])

        let contour = ccwSquareContour()
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Holding tabs

    /// Profiles a straight 20mm line on-contour with a single holding tab
    /// centered at its midpoint. Mirrors "A holding tab clamps depth locally
    /// without affecting the rest of the pass": everywhere but the tab span
    /// cuts to full depth (-3.0), while the tab itself is clamped to its
    /// remaining-stock floor (-1.5) so the part stays attached to the stock.
    func demoHoldingTab() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 0.1)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)
        let tab = SC.HoldingTab(positionRatio: 0.5, width: 2.0, height: 1.5)

        let operation: SC.MachiningOperation = .contour(side: .onContour,
                                                        direction: .climb,
                                                        entry: .plunge,
                                                        leadIn: nil,
                                                        leadOut: nil,
                                                        tabs: [tab])

        let contour = fourSegmentLineContour()
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    func demoHoldingTabRectangle() -> Demo.DemoResult {
        let width = 40.0
        let height = 20.0
        let perimeter = 2 * (width + height)

        let bottomMidDistance = width / 2
        let rightMidDistance = width + height / 2
        let topMidDistance = width + height + width / 2
        let leftMidDistance = width + height + width + height / 2

        let tabs = [bottomMidDistance, rightMidDistance, topMidDistance, leftMidDistance].map {
            SC.HoldingTab(positionRatio: $0 / perimeter, width: 3.0, height: 1.5)
        }

        let tool = SC.ToolParams(diameter: 3.175)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 0.1)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .contour(side: .onContour,
                                                        direction: .climb,
                                                        entry: .plunge,
                                                        leadIn: nil,
                                                        leadOut: nil,
                                                        tabs: tabs)

        let contour = ccwRectangleContour(width: width, height: height)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }
}
