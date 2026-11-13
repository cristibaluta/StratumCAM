//
//  DemoChamfer.swift
//  StratumCAM
//

import Foundation
import StratumCAM

class DemoChamfer: Demo {

    /// A closed CCW rectangle contour: the part's edge to be chamfered.
    private func rectangleContour(width: Double = 30, height: Double = 20, originX: Double = 0, originY: Double = 0) -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(originX, originY), b: SIMD2<Double>(originX + width, originY)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(originX + width, originY), b: SIMD2<Double>(originX + width, originY + height)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(originX + width, originY + height), b: SIMD2<Double>(originX, originY + height)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(originX, originY + height), b: SIMD2<Double>(originX, originY)), reversed: false)
        ], isClosed: true)
    }

    private func settings(stepdown: Double) -> SC.MachineSettings {
        SC.MachineSettings(cutting: SC.CuttingData(feedRate: 800.0,
                                                   plungeRate: 300.0,
                                                   stepdown: stepdown),
                           safeZ: 5.0,
                           targetDepth: 1.0)
    }

    // MARK: - Top edge

    /// The contour is the edge on the top surface (Z 0). The bevel is cut from Z 0 down by its
    /// depth and the tool tip finishes ON the outline, so with a sharp tip and no tip offset the
    /// tool center follows the outline itself. 90 degree V-bit, so width and depth are both
    /// 0.5mm. Stepdown passes on the SAME XY path -- only Z changes, and the bevel widens with
    /// each pass until the last one.
    func demoChamferTopEdge() -> Demo.DemoResult {
        let fluteLength = (3.175 - 0) / 2 / tan((90.0 / 2).degreesToRadians) // 1.59
        let tool = SC.ToolParams(name: "90° V-bit", type: .vBit, diameter: 3.175, vAngle: 90.0, tipWidth: 0, fluteLength: fluteLength)
        let params = SC.ChamferParams(width: 0.5, side: .outside, direction: .climb, edge: .top, tipOffset: 0)

        return run(contour: rectangleContour(),
                   tool: tool,
                   settings: settings(stepdown: 0.1),
                   operation: .chamfer(params: params))
    }

    // MARK: - Bottom edge

    /// The contour is the bevel's LOWER edge, i.e. the part's wall, so the outline is drawn 1.5mm
    /// below the stock top. The bevel is cut from the top down and ends on the outline: the tool
    /// center follows the outline itself (sharp tip) and only Z steps down.
    func demoChamferBottomEdge() -> Demo.DemoResult {
        let fluteLength = (3.175 - 0) / 2 / tan((90.0 / 2).degreesToRadians) // 1.59
        let tool = SC.ToolParams(name: "90° V-bit", type: .vBit, diameter: 3.175, vAngle: 90.0, tipWidth: 0, fluteLength: fluteLength)
        let params = SC.ChamferParams(width: 0.5, side: .outside, direction: .climb, edge: .bottom, tipOffset: 0)

        return run(contour: rectangleContour(),
                   tool: tool,
                   settings: settings(stepdown: 0.1),
                   operation: .chamfer(params: params))
    }

    /// Bottom edge of a wall that sits 4mm below the stock top (`edgeZ` = -4): the bevel runs from
    /// Z -4 up to Z -2.5, and the tool tip finishes at -4. Conventional direction.
    func demoChamferBottomEdgeAtDepth() -> Demo.DemoResult {
        let fluteLength = (3.175 - 0) / 2 / tan((90.0 / 2).degreesToRadians) // 1.59
        let tool = SC.ToolParams(name: "90° V-bit", type: .vBit, diameter: 3.175, vAngle: 90.0, tipWidth: 0, fluteLength: fluteLength)
        let params = SC.ChamferParams(width: 0.5, side: .outside, direction: .conventional, edge: .bottom, edgeZ: -2.0, tipOffset: 0)

        return run(contour: rectangleContour(),
                   tool: tool,
                   settings: settings(stepdown: 0.1),
                   operation: .chamfer(params: params))
    }

    // MARK: - Inside

    /// Breaks the rim of a rectangular opening: the tool works inside the outline, the contour is the
    /// bevel's top edge, the bevel descends toward the tool.
    func demoChamferInsideRim() -> Demo.DemoResult {
        let fluteLength = (3.175 - 0) / 2 / tan((90.0 / 2).degreesToRadians) // 1.59
        let tool = SC.ToolParams(name: "90° V-bit", type: .vBit, diameter: 3.175, vAngle: 90.0, tipWidth: 0, fluteLength: fluteLength)
        let params = SC.ChamferParams(width: 0.5, side: .inside, direction: .climb, edge: .top, tipOffset: 0.5)

        return run(contour: rectangleContour(),
                   tool: tool,
                   settings: settings(stepdown: 0.5),
                   operation: .chamfer(params: params))
    }

    // MARK: - Other tools

    /// A 60 degree V-bit: the bevel is steeper, so a 1mm wide bevel is 1.73mm deep (width and depth
    /// are equal only for a 90 degree bit). The tool's flank is 5.2mm tall.
    func demoChamfer60DegreeBit() -> Demo.DemoResult {
        let fluteLength = (3.175 - 0.3) / 2 / tan((60.0 / 2).degreesToRadians) //
        let tool = SC.ToolParams(name: "60° V-bit 0.3mm tip", type: .vBit, diameter: 3.175, vAngle: 60.0, tipWidth: 0.3, fluteLength: fluteLength)
        let params = SC.ChamferParams(width: 1.0, side: .outside, direction: .climb, edge: .top, tipOffset: 0)

        return run(contour: rectangleContour(),
                   tool: tool,
                   settings: settings(stepdown: 0.1),
                   operation: .chamfer(params: params))
    }

    func demoChamferTipFlatAndTipOffset() -> Demo.DemoResult {
        let fluteLength = (3.175 - 0) / 2 / tan((90.0 / 2).degreesToRadians) // 1.59
        let tool = SC.ToolParams(name: "90° V-bit", type: .vBit, diameter: 3.175, vAngle: 90.0, tipWidth: 0, fluteLength: fluteLength)
        let params = SC.ChamferParams(width: 0.5, side: .outside, direction: .climb, edge: .top, tipOffset: 0.5)

        return run(contour: rectangleContour(),
                   tool: tool,
                   settings: settings(stepdown: 0.1),
                   operation: .chamfer(params: params))
    }
}
