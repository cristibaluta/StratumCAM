//
//  DemoEndMillDrillingContour.swift
//  StratumCAM
//
//  Holes made with a flat end mill by following the hole wall: an inside `.contour` on a
//  circle. The tool centre travels on a circle one tool radius inside the hole, so the hole
//  must be wider than the bit. A hole narrower than the bit makes the offset collapse: the
//  engine throws `SC.Error.geometryCollapsed` and the demo shows that on screen.
//

import Foundation
import StratumCAM

class DemoEndMillDrillingContour: Demo {

    // MARK: - Fixtures

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

    private var settings: SC.MachineSettings {
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0)
        return SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)
    }

    /// The hole wall, cut from the inside.
    private var holeOperation: SC.MachiningOperation {
        .contour(side: .inside,
                 direction: .climb,
                 entry: .plunge,
                 leadIn: nil,
                 leadOut: nil,
                 tabs: [])
    }

    /// Dashed outline of the bit at each given centre, so it's visible that the bit is the
    /// bigger of the two. Keeps the toolpath batch last (see `ContentView.show`).
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

    // MARK: - Hole wider than the bit

    /// Ø8 hole, Ø3.175 bit: the bit fits, so the tool centre follows a circle of radius
    /// 4 - 1.5875 = 2.4125 and the cut edge lands exactly on the wall. Three Z layers.
    func demoHoleWiderThanBit() -> Demo.DemoResult {
        run(contour: circleContour(center: (0, 0), radius: 4.0),
            tool: endMill,
            settings: settings,
            operation: holeOperation)
    }

    // MARK: - Hole narrower than the bit

    /// Ø2 hole, same Ø3.175 bit: the bit can't fit. The inside offset collapses, the engine
    /// throws `SC.Error.geometryCollapsed`, and the red banner shows the error. Blue dashed
    /// is the hole, orange dashed is the bit.
    func demoHoleNarrowerThanBit() -> Demo.DemoResult {
        let tool = endMill
        let result = run(contour: circleContour(center: (0, 0), radius: 1.0),
                         tool: tool,
                         settings: settings,
                         operation: holeOperation)
        return addingToolOutlines(to: result, centers: [(0, 0)], tool: tool)
    }

    // MARK: - One wider, one narrower

    /// A Ø8 hole next to a Ø2 hole, same bit. The wide one gets its toolpath; the narrow one
    /// throws and is reported by name in the banner. Each hole is generated on its own
    /// (`isolatingErrors`), because one engine call with both holes would fail as a whole.
    func demoOneWiderOneNarrower() -> Demo.DemoResult {
        let tool = endMill
        let holes: [(center: (Double, Double), radius: Double)] = [
            ((0, 0), 4.0),
            ((14, 0), 1.0)
        ]
        let result = run(contours: holes.map { circleContour(center: $0.center, radius: $0.radius) },
                         tool: tool,
                         settings: settings,
                         operation: holeOperation,
                         isolatingErrors: true,
                         contourLabel: { index in
                             String(format: "Hole %d (Ø%.4g mm)", index + 1, holes[index].radius * 2)
                         })

        // Outline the bit only where it didn't fit.
        return addingToolOutlines(to: result, centers: [holes[1].center], tool: tool)
    }
}
