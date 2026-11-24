//
//  DemoEntries.swift
//  StratumCAM
//
//  How the tool gets down into the material: the two angled entries, ramp and helix, on a
//  rectangle and on a circle, each cut from the inside and from the outside.
//
//  Every demo uses the same Ø6 end mill, 3 Z layers of 1 mm and a 3° entry angle, so the only
//  things that change between two demos are the ones in their title.
//
//  Contour demos (`.contour`)
//  - Outside: the tool runs around the outside of the shape, like profiling a part.
//  - Inside: the tool runs around the inside of the shape, like cutting a hole or a window.
//  The ramp/helix is made on the contour itself, in the waste, so the entry lands on the wall
//  at full depth.
//
//  Pocket demos (`.pocket`)
//  - The whole area is cleared with concentric rings from the centre out. The ramp/helix is
//    made at the head of the toolpath, in the middle of the shape.
//

import Foundation
import StratumCAM

class DemoEntries: Demo {

    // MARK: - Fixtures

    /// Rectangle size: wide enough for a ramp to fit along one edge, tall enough for the tool.
    private let rectWidth = 40.0
    private let rectHeight = 24.0

    /// Circle radius.
    private let circleRadius = 15.0

    private let entryAngle = 3.0

    private var tool: SC.ToolParams {
        SC.ToolParams(diameter: 6.0)
    }

    private var settings: SC.MachineSettings {
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        return SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)
    }

    private var ramp: SC.EntryStrategy {
        .ramp(angleDegrees: entryAngle)
    }

    private var helix: SC.EntryStrategy {
        .helix(rampAngleDegrees: entryAngle)
    }

    private func rectangleContour() -> SC.Contour {
        let w = rectWidth
        let h = rectHeight
        return SC.Contour(entities: [
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(w, 0)), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(w, 0), b: SIMD2<Double>(w, h)), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(w, h), b: SIMD2<Double>(0, h)), reversed: false),
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(0, h), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true)
    }

    private func circleContour() -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(geometry: .circle(center: SIMD2<Double>(0, 0), radius: circleRadius), reversed: false)
        ], isClosed: true)
    }

    // MARK: - Runners

    private func contourDemo(_ contour: SC.Contour,
                             side: SC.CutSide,
                             entry: SC.EntryStrategy,
                             settings customSettings: SC.MachineSettings? = nil) -> Demo.DemoResult {
        let operation: SC.MachiningOperation = .contour(side: side,
                                                        direction: .climb,
                                                        entry: entry,
                                                        leadIn: nil,
                                                        leadOut: nil,
                                                        tabs: [])
        return run(contour: contour, tool: tool, settings: customSettings ?? settings, operation: operation)
    }

    private func pocketDemo(_ contour: SC.Contour, entry: SC.EntryStrategy) -> Demo.DemoResult {
        let operation: SC.MachiningOperation = .pocket(direction: .climb,
                                                       pattern: .concentric(direction: .insideOut),
                                                       entry: entry)
        return run(contour: contour, tool: tool, settings: settings, operation: operation)
    }

    // MARK: - Rectangle, contour

    /// Profile of a 40x24 rectangle, cut from the outside. The ramp zig-zags along the first
    /// edge, outside the part, and lands on the wall at full depth.
    func demoRectOutsideRamp() -> Demo.DemoResult {
        contourDemo(rectangleContour(), side: .outside, entry: ramp)
    }

    /// Same profile, entered with a helix beside the start point instead of a ramp.
    func demoRectOutsideHelix() -> Demo.DemoResult {
        contourDemo(rectangleContour(), side: .outside, entry: helix)
    }

    /// A 40x24 window cut from the inside. The ramp zig-zags along the first edge, inside the
    /// window, where there is room for it.
    func demoRectInsideRamp() -> Demo.DemoResult {
        contourDemo(rectangleContour(), side: .inside, entry: ramp)
    }

    /// Same window, entered with a helix inside it. The loop starts at a corner, so the helix is
    /// centered the same distance from both walls instead of tangent to just one of them; after the
    /// last turn the tool moves along the floor to the corner.
    func demoRectInsideHelix() -> Demo.DemoResult {
        contourDemo(rectangleContour(), side: .inside, entry: helix)
    }

    // MARK: - Circle, contour

    /// Profile of a Ø30 disc, cut from the outside, entered with a ramp along the circle.
    func demoCircleOutsideRamp() -> Demo.DemoResult {
        contourDemo(circleContour(), side: .outside, entry: ramp)
    }

    /// Same disc, entered with a helix.
    func demoCircleOutsideHelix() -> Demo.DemoResult {
        contourDemo(circleContour(), side: .outside, entry: helix)
    }

    /// A Ø30 hole cut from the inside, entered with a ramp along the wall.
    func demoCircleInsideRamp() -> Demo.DemoResult {
        contourDemo(circleContour(), side: .inside, entry: ramp)
    }

    /// Same hole, entered with a helix.
    func demoCircleInsideHelix() -> Demo.DemoResult {
        contourDemo(circleContour(), side: .inside, entry: helix)
    }

    // MARK: - Custom start Z

    /// The 40x24 profile again, with the first ramp starting 2 mm above the stock
    /// (`MachineSettings.rampStartZ`) instead of at the surface. The first pass slopes down in
    /// the air from Z +2, through the surface, to -1; the second pass starts from -1 and the
    /// third from -2, the Z the pass before them already cut. A 3 mm drop at 3° is about 57 mm
    /// of travel, so the first ramp spans most of the first lap.
    func demoRectOutsideRampFromCustomZ() -> Demo.DemoResult {
        var custom = settings
        custom.startOffset = 2.0
        return contourDemo(rectangleContour(), side: .outside, entry: ramp, settings: custom)
    }

    // MARK: - Pocket

    /// 40x24 pocket cleared from the centre out, entered with a ramp.
    func demoPocketRectRamp() -> Demo.DemoResult {
        pocketDemo(rectangleContour(), entry: ramp)
    }

    /// 40x24 pocket cleared from the centre out, entered with a helix.
    func demoPocketRectHelix() -> Demo.DemoResult {
        pocketDemo(rectangleContour(), entry: helix)
    }

    /// Ø30 pocket cleared from the centre out, entered with a ramp.
    func demoPocketCircleRamp() -> Demo.DemoResult {
        pocketDemo(circleContour(), entry: ramp)
    }

    /// Ø30 pocket cleared from the centre out, entered with a helix centred on the circle.
    func demoPocketCircleHelix() -> Demo.DemoResult {
        pocketDemo(circleContour(), entry: helix)
    }
}
