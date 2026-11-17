//
//  DemoContourGaps.swift
//  StratumCAM
//
//  Contours that are pieces of one outline: a 3D part projected to Z0 leaves one outline split
//  over several open contours. With `closeGaps` (on by default) the engine chains them back
//  together before it calculates the toolpath.
//

import Foundation
import StratumCAM

class DemoContourGaps: Demo {

    // MARK: - Fixtures

    /// Consecutive points as a chain of lines.
    private func lines(_ points: [(Double, Double)]) -> [SC.Contour.Chained] {
        zip(points, points.dropFirst()).map { a, b in
            SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(a.0, a.1), b: SIMD2<Double>(b.0, b.1)), reversed: false)
        }
    }

    /// A crescent-shaped slot projected from a 3D part. The outline is split in two open
    /// contours: the first runs from the top bump round the outer edge and back along the
    /// inner edge; the second is the middle of the inner edge, drawn in the opposite direction
    /// (it has to be flipped), with a gap at each end.
    private static let crescentOuter: [(Double, Double)] = [
        (106.361, 37.863), (106.309, 38.327), (106.247, 38.791), (106.590, 38.751),
        (106.934, 38.768), (107.271, 38.841), (107.592, 38.968), (107.887, 39.146),
        (108.150, 39.370), (108.372, 39.480), (108.614, 39.532), (108.862, 39.524),
        (109.099, 39.454), (109.313, 39.328), (109.489, 39.154), (109.617, 38.941),
        (109.688, 38.704), (109.732, 38.317), (109.770, 37.929), (109.853, 36.725),
        (109.880, 35.520), (109.852, 34.313), (109.770, 33.108), (109.608, 31.731),
        (109.374, 30.365), (109.069, 29.013), (108.693, 27.679), (108.249, 26.366),
        (107.736, 25.078), (107.157, 23.819), (106.512, 22.592), (105.805, 21.400),
        (105.036, 20.247), (104.208, 19.135), (103.322, 18.069), (102.383, 17.050),
        (102.146, 16.910), (101.880, 16.839), (101.605, 16.844), (101.342, 16.923),
        (101.110, 17.071), (100.928, 17.276), (100.808, 17.524), (100.731, 17.857),
        (100.601, 18.173), (100.422, 18.464), (100.198, 18.722), (99.935, 18.940),
        (99.640, 19.112), (100.480, 19.990), (101.273, 20.910), (102.016, 21.871),
        (102.708, 22.870), (103.346, 23.903), (103.930, 24.969)
    ]

    private static let crescentInner: [(Double, Double)] = [
        (106.363, 33.194), (106.189, 31.863), (105.938, 30.544), (105.610, 29.241),
        (105.208, 27.960), (104.732, 26.705)
    ]

    private func crescentContours() -> [SC.Contour] {
        [
            SC.Contour(entities: lines(Self.crescentOuter), isClosed: false),
            SC.Contour(entities: lines(Self.crescentInner), isClosed: false)
        ]
    }

    /// A 10x10 square split in two open contours: the second one is drawn the other way round.
    private func splitSquareContours() -> [SC.Contour] {
        [
            SC.Contour(entities: lines([(0, 0), (10, 0), (10, 10)]), isClosed: false),
            SC.Contour(entities: lines([(0, 6), (0, 10)]), isClosed: false)
        ]
    }

    // MARK: - Demos

    /// The crescent followed exactly on the line (`.onContour`), the way it was reported: the
    /// two contours become one closed outline, joined by a short bridge at each end of the
    /// inner edge's missing stretch.
    func demoCrescentOnContour() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 0.1)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .contour(side: .onContour,
                                                        direction: .climb,
                                                        entry: .plunge,
                                                        leadIn: nil,
                                                        leadOut: nil,
                                                        tabs: [])

        return self.run(contours: crescentContours(), tool: tool, settings: settings, operation: operation)
    }

    /// The same crescent cut on the inside of the closed outline, with a 1 mm tool that fits
    /// the narrow slot.
    func demoCrescentInside() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 1.0)
        let cutting = SC.CuttingData(feedRate: 800.0, plungeRate: 300.0, stepdown: 0.1)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .contour(side: .inside,
                                                        direction: .climb,
                                                        entry: .plunge,
                                                        leadIn: nil,
                                                        leadOut: nil,
                                                        tabs: [])

        return self.run(contours: crescentContours(), tool: tool, settings: settings, operation: operation)
    }

    /// The simplest case: a square in two open contours, the second drawn backwards. Outside
    /// profile of the closed square.
    func demoSplitSquareOutside() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 0.1)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)

        let operation: SC.MachiningOperation = .contour(side: .outside,
                                                        direction: .climb,
                                                        entry: .plunge,
                                                        leadIn: nil,
                                                        leadOut: nil,
                                                        tabs: [])

        return self.run(contours: splitSquareContours(), tool: tool, settings: settings, operation: operation)
    }

    /// A pocket whose outline is split over several open contours with a gap between them, the
    /// way lines at different Z heights look once projected: a 40x24 rectangle in three pieces
    /// (one drawn backwards, one with a small gap), plus a square island split in two. The
    /// engine chains and closes each outline before it detects the island.
    func demoSplitPocket() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 4.0)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)

        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .offset, entry: .plunge)

        let contours = [
            SC.Contour(entities: lines([(0, 0), (40, 0)]), isClosed: false),
            SC.Contour(entities: lines([(40, 24), (40, 0)]), isClosed: false),
            SC.Contour(entities: lines([(40, 24), (0, 24), (0, 0.2)]), isClosed: false),
            SC.Contour(entities: lines([(15, 8), (25, 8), (25, 16)]), isClosed: false),
            SC.Contour(entities: lines([(15, 8), (15, 16), (25, 16)]), isClosed: false)
        ]
        return self.run(contours: contours, tool: tool, settings: settings, operation: operation)
    }
}
