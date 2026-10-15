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

    /// A pendant/keyring shape: a big circular body with a small loop at the top,
    /// joined by a narrow "neck" -- the exact shape from the reported "toolpath went
    /// crazy" bug, reduced to its essentials. Each side of the neck has a small
    /// zigzag notch (mimicking the tiny stray segments a raster-trace/auto-vectorize
    /// leaves at a pinch point) where the path folds back on itself by ~178 degrees.
    /// That's sharp enough that a line-line "trim" at that corner, if solved as an
    /// infinite-line miter join, lands roughly 57x the tool radius away from the real
    /// vertex -- see `SCEngine+Offset.swift`'s `maxReasonableTrimDistance` comment.
    ///
    /// `foldsTowardCenterline` picks which way the notch folds. A corner's
    /// fillet-vs-trim classification depends on the *sign* of its local turn against
    /// the offset distance's sign -- so for a given fold direction, exactly one of
    /// `.outside`/`.inside` lands this notch in the buggy trim branch and the other in
    /// the stable fillet branch. `false` (folding away from the centerline) hits it on
    /// `.outside`; `true` (folding toward the centerline) hits it on `.inside` --
    /// that's why the two demos below use different fixtures rather than the same one
    /// with the side flipped: a single symmetric notch pair doesn't reproduce both.
    private func narrowNeckPendantContour(notchFoldsTowardCenterline: Bool) -> SC.Contour {
        // Main body.
        let bodyCenter = DXF.Point(0, 0)
        let bodyRadius = 25.0
        // Junction points where the neck meets the body sit at +/-10 degrees either
        // side of straight up (90 degrees), i.e. a 20-degree-wide gap at the top.
        let bodyArc = DXF.Entity.arc(center: bodyCenter, radius: bodyRadius, startDeg: 100, endDeg: 440, layer: "0", color: 7)

        // Loop (the keyring hole) sitting above the body.
        let loopCenter = DXF.Point(0, 60)
        let loopRadius = 9.0
        // Junction points where the neck meets the loop sit at +/-10 degrees either
        // side of straight down (270 degrees), i.e. a 20-degree-wide gap at the bottom.
        let loopArc = DXF.Entity.arc(center: loopCenter, radius: loopRadius, startDeg: 280, endDeg: 620, layer: "0", color: 7)

        // Left neck: body junction -> notch -> loop junction. notchLeft1 is the same
        // in both variants; only notchLeft2 moves, to fold the ~178-degree hairpin one
        // way or the other.
        let bodyLeft = DXF.Point(-4.341, 24.620)
        let notchLeft1 = DXF.Point(-7.278, 29.273)
        let notchLeft2 = notchFoldsTowardCenterline ? DXF.Point(-6.039, 27.454) : DXF.Point(-6.169, 27.372)
        let loopLeft = DXF.Point(-1.563, 51.137)

        // Right neck: mirror image, walked in the opposite direction (loop -> body)
        // so the whole contour reads as one continuous CCW loop.
        let loopRight = DXF.Point(1.563, 51.137)
        let notchRight1 = notchFoldsTowardCenterline ? DXF.Point(6.039, 27.454) : DXF.Point(6.169, 27.372)
        let notchRight2 = DXF.Point(7.278, 29.273)
        let bodyRight = DXF.Point(4.341, 24.620)

        return SC.Contour(
            entities: [
                // Body, the long way around: bodyRight -> ... -> bodyLeft.
                SC.Contour.Chained(entity: bodyArc, reversed: true),
                SC.Contour.Chained(entity: .line(a: bodyLeft, b: notchLeft1, layer: "0", color: 7), reversed: false),
                SC.Contour.Chained(entity: .line(a: notchLeft1, b: notchLeft2, layer: "0", color: 7), reversed: false),
                SC.Contour.Chained(entity: .line(a: notchLeft2, b: loopLeft, layer: "0", color: 7), reversed: false),
                // Loop, the long way around: loopLeft -> ... -> loopRight.
                SC.Contour.Chained(entity: loopArc, reversed: true),
                SC.Contour.Chained(entity: .line(a: loopRight, b: notchRight1, layer: "0", color: 7), reversed: false),
                SC.Contour.Chained(entity: .line(a: notchRight1, b: notchRight2, layer: "0", color: 7), reversed: false),
                SC.Contour.Chained(entity: .line(a: notchRight2, b: bodyRight, layer: "0", color: 7), reversed: false)
            ],
            isClosed: true
        )
    }

    // MARK: - Narrow neck (reported bug repro)

    /// Reproduces the reported "toolpath went crazy" bug on an outside contour offset
    /// around the pendant's narrow neck. Before the fix, the two neck notches spiked
    /// to ~57x the tool radius away from the pendant; after the `maxReasonableTrimDistance`
    /// fix alone (an earlier iteration of this fix), they became a straight-line
    /// shortcut that cut across the notch instead of following it; with the current
    /// fix they're a tool-radius arc pivoting around the notch's own tip instead.
    func demoNarrowNeckOutside() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 0.1)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .contour(side: .outside,
                                                        direction: .climb,
                                                        entry: .plunge,
                                                        leadIn: nil,
                                                        leadOut: nil,
                                                        tabs: [])

        let contour = narrowNeckPendantContour(notchFoldsTowardCenterline: false)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    /// Reproduces the same bug on an inside contour offset -- a mirror-image notch
    /// fixture from `demoNarrowNeckOutside()` (see `narrowNeckPendantContour(notchFoldsTowardCenterline:)`),
    /// since it's the notch's fold direction relative to the offset side that decides
    /// which one lands in the buggy trim branch.
    func demoNarrowNeckInside() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 6.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 0.1)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .contour(side: .inside,
                                                        direction: .climb,
                                                        entry: .plunge,
                                                        leadIn: nil,
                                                        leadOut: nil,
                                                        tabs: [])

        let contour = narrowNeckPendantContour(notchFoldsTowardCenterline: true)
        return self.run(contour: contour, tool: tool, settings: settings, operation: operation)
    }
}
