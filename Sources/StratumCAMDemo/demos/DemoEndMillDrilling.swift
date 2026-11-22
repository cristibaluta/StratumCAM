//
//  DemoEndMillDrilling.swift
//  StratumCAM
//
//  Holes made with a flat end mill instead of a drill. The hole is not plunged: it is
//  a circular `.pocket`, cleared inside-out with concentric circles from a helix entry,
//  so the hole can be wider than the bit. A hole narrower than the bit can't be cut at
//  all: the engine throws `SC.Error.geometryCollapsed` and the demo shows that on screen.
//

import Foundation
import StratumCAM

class DemoEndMillDrilling: Demo {

    // MARK: - Fixtures

    private let holeColor = SIMD4<Float>(0.2, 0.8, 1.0, 1.0)
    private let toolOutlineColor = SIMD4<Float>(1.0, 0.45, 0.1, 1.0)

    private func circleContour(center: (Double, Double), radius: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(geometry: .circle(center: SIMD2<Double>(center.0, center.1), radius: radius), reversed: false)
        ], isClosed: true)
    }

    /// 1/8" flat end mill, the tool every demo here uses.
    private var endMill: SC.ToolParams {
        SC.ToolParams(type: .flatEndMill, diameter: 3.175)
    }

    private func settings(targetDepth: Double = -3.0, allowance: Double = 0, finishingPass: Bool = false) -> SC.MachineSettings {
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.25)
        return SC.MachineSettings(cutting: cutting,
                                  safeZ: 5.0,
                                  targetDepth: targetDepth,
                                  allowance: allowance,
                                  finishingPass: finishingPass)
    }

    /// A hole is a circular pocket: concentric circles from the centre out, helix entry.
    private var holeOperation: SC.MachiningOperation {
        .pocket(direction: .climb,
                pattern: .concentric(direction: .insideOut),
                entry: .helix(rampAngleDegrees: 3.0))
    }

    /// Dashed outline of the bit, drawn at each hole centre, so it's visible that the bit
    /// is the bigger of the two. Keeps the toolpath batch last (see `ContentView.show`).
    private func addingToolOutlines(to result: Demo.DemoResult, centers: [(Double, Double)], tool: SC.ToolParams) -> Demo.DemoResult {
        var extra: [RenderBatch] = []
        for (x, y) in centers {
            let points = Demo.circleReferencePoints(centerX: x, centerY: y, diameter: tool.diameter)
            if let batch = renderBatch(forPoints: points, color: toolOutlineColor, isDashed: true, dashLength: 0.3) {
                extra.append(batch)
            }
        }
        var batches = result.batches
        if !result.toolpathPoints.isEmpty && !batches.isEmpty {
            batches.insert(contentsOf: extra, at: batches.count - 1)
        } else {
            batches.append(contentsOf: extra)
        }
        return Demo.DemoResult(batches: batches,
                               gcode: result.gcode,
                               toolpathPoints: result.toolpathPoints,
                               tool: result.tool,
                               errorMessage: result.errorMessage,
                               info: result.info)
    }

    // MARK: - Holes wider than the bit

    /// Ø8 hole with a Ø3.175 bit: plenty of room, so the helix enters at the centre and
    /// concentric circles grow out to the wall. Three Z layers.
    func demoHoleWiderThanBit() -> Demo.DemoResult {
        run(contour: circleContour(center: (0, 0), radius: 4.0),
            tool: endMill,
            settings: settings(),
            operation: holeOperation)
    }

    /// Ø2 hole with the same Ø3.175 bit: the bit is wider than the hole, so it can't fit.
    /// The engine throws `SC.Error.geometryCollapsed`, there is no toolpath and no G-code,
    /// and the red banner on the canvas shows the error. The blue dashed circle is the hole,
    /// the orange dashed one is the bit.
    func demoHelixEntrySmallHole() -> Demo.DemoResult {
        let tool = endMill
        let result = run(contour: circleContour(center: (0, 0), radius: 1.0),
                         tool: tool,
                         settings: settings(),
                         operation: holeOperation)
        return addingToolOutlines(to: result, centers: [(0, 0)], tool: tool)
    }

    /// Three holes of different diameters (Ø5, Ø8, Ø12), all wider than the bit, one toolpath each.
    func demoMultipleHolesWiderThanBit() -> Demo.DemoResult {
        let contours = [
            circleContour(center: (0, 0), radius: 2.5),
            circleContour(center: (16, 0), radius: 4.0),
            circleContour(center: (36, 0), radius: 6.0)
        ]
        return run(contours: contours,
                   tool: endMill,
                   settings: settings(),
                   operation: holeOperation)
    }

    // MARK: - Material left + finishing pass

    /// Ø10 hole roughed with 0.3 mm of stock left on the wall and on the floor, and no
    /// finishing pass: the yellow path stops 0.3 mm short of the blue wall and 0.3 mm above
    /// the full depth.
    func demoHoleMaterialLeft() -> Demo.DemoResult {
        run(contour: circleContour(center: (0, 0), radius: 5.0),
            tool: endMill,
            settings: settings(allowance: 0.3, finishingPass: false),
            operation: holeOperation)
    }

    /// Same Ø10 hole and the same 0.3 mm of stock, followed by the finishing pass: after the
    /// roughing, a floor pass at full depth and then one lap on the wall with the real tool,
    /// so the hole ends at its true size.
    func demoHoleMaterialLeftWithFinishingPass() -> Demo.DemoResult {
        run(contour: circleContour(center: (0, 0), radius: 5.0),
            tool: endMill,
            settings: settings(allowance: 0.3, finishingPass: true),
            operation: holeOperation)
    }

    /// Three holes (Ø6, Ø9, Ø12), each roughed with 0.3 mm left and then finished.
    func demoMultipleHolesMaterialLeftWithFinishingPass() -> Demo.DemoResult {
        let contours = [
            circleContour(center: (0, 0), radius: 3.0),
            circleContour(center: (14, 0), radius: 4.5),
            circleContour(center: (32, 0), radius: 6.0)
        ]
        return run(contours: contours,
                   tool: endMill,
                   settings: settings(allowance: 0.3, finishingPass: true),
                   operation: holeOperation)
    }

    // MARK: - One wider, one smaller

    /// A Ø8 hole next to a Ø2 hole, same Ø3.175 bit. The wide one gets its toolpath; the
    /// small one throws and is reported by name in the banner. Each hole is generated on its
    /// own (`isolatingErrors`), because one engine call with both holes would fail as a whole.
    func demoOneWiderOneSmaller() -> Demo.DemoResult {
        let tool = endMill
        let holes: [(center: (Double, Double), radius: Double)] = [
            ((0, 0), 4.0),
            ((14, 0), 1.0)
        ]
        let result = run(contours: holes.map { circleContour(center: $0.center, radius: $0.radius) },
                         tool: tool,
                         settings: settings(),
                         operation: holeOperation,
                         isolatingErrors: true,
                         contourLabel: { index in
                             String(format: "Hole %d (Ø%.4g mm)", index + 1, holes[index].radius * 2)
                         })

        // Outline the bit only where it didn't fit.
        return addingToolOutlines(to: result, centers: [holes[1].center], tool: tool)
    }
}
