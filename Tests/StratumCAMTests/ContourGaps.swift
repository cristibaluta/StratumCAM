//
//  ContourGaps_Tests.swift
//  StratumCAM
//
//  Closing the gaps between the open contours of one outline (`closeGaps`).
//

import Testing
import Foundation
import simd
@testable import StratumCAM

struct ContourGaps_Tests {

    // MARK: - Helpers

    private func line(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> SC.Contour.Chained {
        SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(ax, ay), b: SIMD2<Double>(bx, by)), reversed: false)
    }

    /// Consecutive points as a chain of lines.
    private func lines(_ points: [(Double, Double)]) -> [SC.Contour.Chained] {
        zip(points, points.dropFirst()).map { a, b in line(a.0, a.1, b.0, b.1) }
    }

    private func open(_ points: [(Double, Double)]) -> SC.Contour {
        SC.Contour(entities: lines(points), isClosed: false)
    }

    /// Every segment starts where the previous one ends, and the last one ends where the first starts.
    private func isContinuousLoop(_ contour: SC.Contour, tolerance: Double = 1e-9) -> Bool {
        let segments = contour.linearizedSegments
        guard let first = segments.first, let last = segments.last else {
            return false
        }
        for (a, b) in zip(segments, segments.dropFirst()) {
            if hypot(a.endPoint.x - b.startPoint.x, a.endPoint.y - b.startPoint.y) > tolerance {
                return false
            }
        }
        return hypot(last.endPoint.x - first.startPoint.x, last.endPoint.y - first.startPoint.y) <= tolerance
    }

    private func length(of contour: SC.Contour) -> Double {
        contour.linearizedSegments.reduce(0) { $0 + hypot($1.endPoint.x - $1.startPoint.x, $1.endPoint.y - $1.startPoint.y) }
    }

    /// A 10x10 square in two open contours; the second one is drawn the other way round.
    private func splitSquare(offsetX: Double = 0) -> [SC.Contour] {
        [
            open([(offsetX, 0), (offsetX + 10, 0), (offsetX + 10, 10)]),
            open([(offsetX, 6), (offsetX, 10)])
        ]
    }

    private let engine = SCEngine()

    private let contourOperation: (SC.CutSide) -> SC.MachiningOperation = { side in
        .contour(side: side, direction: .climb, entry: .plunge, leadIn: nil, leadOut: nil, tabs: [])
    }

    // MARK: - Merging

    @Test("Two open contours of one outline become one closed contour")
    func mergesTwoOpenContours() {
        let result = engine.closingGaps(in: splitSquare())

        #expect(result.count == 1)
        #expect(result[0].isClosed)
        // 2 lines + bridge + the second contour + closing bridge.
        #expect(result[0].entities.count == 5)
        #expect(isContinuousLoop(result[0]))
        // 10 + 10 + 10 (bridge) + 4 + 6 (closing bridge)
        #expect(abs(length(of: result[0]) - 40) < 1e-9)
    }

    @Test("A contour drawn the other way round is flipped to follow the walk")
    func flipsTheSecondContour() {
        let result = engine.closingGaps(in: splitSquare())

        // entities: 0, 1 = first contour, 2 = bridge, 3 = second contour, 4 = closing bridge
        #expect(result[0].entities[3].reversed)
        #expect(!result[0].entities[0].reversed)
    }

    @Test("The ends are joined to the closest free end, not to the next contour in the list")
    func joinsTheClosestEnd() {
        // The first contour ends at (10, 10); the contour listed second is far away, the one
        // listed third is the one that touches the outline's gap.
        let contours = [
            open([(0, 0), (10, 0), (10, 10)]),
            open([(200, 200), (210, 200)]),
            open([(0, 10), (0, 6)])
        ]
        let result = engine.closingGaps(in: contours)

        #expect(result.count == 2)
        #expect(result[0].isClosed)
        #expect(result[0].entities.count == 5)
        // The far contour is left on its own (it has nothing near to close against).
        #expect(result[1].entities.count == 2)
        #expect(result[1].isClosed)
    }

    @Test("A single open contour is closed back onto its start")
    func closesASingleContour() {
        let result = engine.closingGaps(in: [open([(0, 0), (10, 0), (10, 10), (0, 10)])])

        #expect(result.count == 1)
        #expect(result[0].isClosed)
        #expect(result[0].entities.count == 4)
        #expect(isContinuousLoop(result[0]))
    }

    @Test("Entities that arrive in the wrong order or direction are chained")
    func reordersEntities() {
        let contour = SC.Contour(entities: [
            line(10, 10, 0, 10),   // 3rd, as drawn
            line(0, 0, 10, 0),     // 1st
            line(10, 10, 10, 0),   // 2nd, drawn backwards
        ], isClosed: false)
        let result = engine.closingGaps(in: [contour])

        #expect(result.count == 1)
        #expect(isContinuousLoop(result[0]))
        #expect(result[0].isClosed)
    }

    // MARK: - What is left alone

    @Test("A contour that is already closed is not touched")
    func keepsClosedContours() {
        let square = SC.Contour(entities: lines([(0, 0), (10, 0), (10, 10), (0, 10), (0, 0)]), isClosed: true)
        let result = engine.closingGaps(in: [square])

        #expect(result.count == 1)
        #expect(result[0].entities.count == 4)
        #expect(result[0].isClosed)
    }

    @Test("Only the unclosed contours are merged, closed ones keep their place")
    func mergesOnlyTheUnclosed() {
        let closed = SC.Contour(entities: lines([(50, 50), (60, 50), (60, 60), (50, 60), (50, 50)]), isClosed: true)
        let result = engine.closingGaps(in: [closed] + splitSquare())

        #expect(result.count == 2)
        #expect(result[0].isClosed)
        #expect(result[0].entities.count == 4)
        #expect(result[1].entities.count == 5)
        #expect(isContinuousLoop(result[1]))
    }

    @Test("Separate outlines are not merged into one")
    func keepsSeparateOutlinesApart() {
        let result = engine.closingGaps(in: splitSquare() + splitSquare(offsetX: 100))

        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.isClosed && $0.entities.count == 5 && isContinuousLoop($0) })
        // Each outline stays in its own place: x in 0...10 and 100...110.
        let firstXs = result[0].linearizedSegments.map { $0.startPoint.x }
        let secondXs = result[1].linearizedSegments.map { $0.startPoint.x }
        #expect(firstXs.allSatisfy { $0 <= 10 })
        #expect(secondXs.allSatisfy { $0 >= 100 })
    }

    @Test("A circle, a point marker or a closed polyline is left as it is")
    func leavesSelfClosedEntitiesAlone() {
        let circle = SC.Contour(entities: [
            SC.Contour.Chained(geometry: .circle(center: SIMD2<Double>(0, 0), radius: 5), reversed: false)
        ], isClosed: false)
        let marker = SC.Contour(entities: [
            SC.Contour.Chained(geometry: .point(at: SIMD2<Double>(1, 1)), reversed: false)
        ], isClosed: false)
        let polyline = SC.Contour(entities: [
            SC.Contour.Chained(geometry: .polyline(vertices: [
                SC.Geometry.Vertex(SIMD2<Double>(0, 0), bulge: 0),
                SC.Geometry.Vertex(SIMD2<Double>(4, 0), bulge: 0),
                SC.Geometry.Vertex(SIMD2<Double>(4, 4), bulge: 0)
            ], closed: true), reversed: false)
        ], isClosed: false)
        let result = engine.closingGaps(in: [circle, marker, polyline])

        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.entities.count == 1 })
        #expect(!result[0].isClosed)
    }

    @Test("Zero-length entities and duplicated lines are dropped")
    func dropsDegenerateAndDuplicates() {
        let contour = SC.Contour(entities: [
            line(0, 0, 10, 0),
            line(10, 0, 0, 0),     // the same line, the other way round
            line(5, 5, 5, 5),      // zero length
            line(10, 0, 10, 10)
        ], isClosed: false)
        let result = engine.closingGaps(in: [contour])

        #expect(result.count == 1)
        // 2 lines + closing bridge
        #expect(result[0].entities.count == 3)
        #expect(isContinuousLoop(result[0]))
    }

    @Test("Islands and topZ of the first contour are kept")
    func keepsIslandsAndTopZ() {
        let island = SC.Contour(entities: lines([(2, 2), (3, 2), (3, 3), (2, 3), (2, 2)]), isClosed: true)
        var first = open([(0, 0), (10, 0), (10, 10)])
        first.islands = [island]
        first.topZ = -2
        let result = engine.closingGaps(in: [first, open([(0, 6), (0, 10)])])

        #expect(result.count == 1)
        #expect(result[0].islands.count == 1)
        #expect(result[0].topZ == -2)
    }

    // MARK: - The reported part

    /// The crescent slot of a 3D part projected to Z0, as it reached the engine.
    private func crescent() -> [SC.Contour] {
        let outer: [(Double, Double)] = [
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
        let inner: [(Double, Double)] = [
            (106.363, 33.194), (106.189, 31.863), (105.938, 30.544), (105.610, 29.241),
            (105.208, 27.960), (104.732, 26.705)
        ]
        return [open(outer), open(inner)]
    }

    @Test("The projected crescent becomes one closed outline with two short bridges")
    func projectedCrescent() {
        let result = engine.closingGaps(in: crescent())

        #expect(result.count == 1)
        #expect(result[0].isClosed)
        // 54 + bridge + 5 + closing bridge
        #expect(result[0].entities.count == 61)
        #expect(isContinuousLoop(result[0]))

        // The second contour is walked from its end to its start.
        #expect(result[0].entities[55...59].allSatisfy { $0.reversed })

        // The two bridges: end of the first contour to the end of the second, and the start of the
        // second back to the start of the first.
        let segments = result[0].linearizedSegments
        func bridgeLength(_ index: Int) -> Double {
            hypot(segments[index].endPoint.x - segments[index].startPoint.x,
                  segments[index].endPoint.y - segments[index].startPoint.y)
        }
        #expect(abs(bridgeLength(54) - 1.912) < 0.01)
        #expect(abs(bridgeLength(60) - 4.669) < 0.01)
    }

    // MARK: - Through the engine

    @Test("generateToolpaths merges the open contours of an outline by default, whatever the side")
    func engineMergesByDefault() throws {
        let tool = SC.ToolParams(diameter: 1.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 0.5),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)

        for side in [SC.CutSide.onContour, .inside, .outside] {
            let toolpaths = try engine.generateToolpaths(from: splitSquare(),
                                                         tool: tool,
                                                         settings: settings,
                                                         operation: contourOperation(side))
            #expect(toolpaths.count == 1, "one toolpath for the merged outline (\(side))")
        }
    }

    @Test("A merged outline is cut as a closed loop")
    func engineCutsAClosedLoop() throws {
        let tool = SC.ToolParams(diameter: 1.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 0.5),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)
        let toolpaths = try engine.generateToolpaths(from: splitSquare(),
                                                     tool: tool,
                                                     settings: settings,
                                                     operation: contourOperation(.onContour))

        let cuts = toolpaths[0].passes[0].waypoints.filter { $0.position.z < 0 }
        let first = try #require(cuts.first)
        let last = try #require(cuts.last)
        #expect(abs(first.position.x - last.position.x) < 1e-6)
        #expect(abs(first.position.y - last.position.y) < 1e-6)
    }

    @Test("closeGaps: false keeps every contour as it came")
    func engineWithoutClosingGaps() throws {
        let tool = SC.ToolParams(diameter: 1.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 0.5),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)
        let toolpaths = try engine.generateToolpaths(from: splitSquare(),
                                                     tool: tool,
                                                     settings: settings,
                                                     operation: contourOperation(.onContour),
                                                     closeGaps: false)

        #expect(toolpaths.count == 2)
    }

    @Test("closeGaps does not change other operations")
    func otherOperationsAreNotMerged() throws {
        let tool = SC.ToolParams(diameter: 1.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 0.5),
                                          safeZ: 5.0,
                                          targetDepth: -1.0)
        let toolpaths = try engine.generateToolpaths(from: splitSquare(),
                                                     tool: tool,
                                                     settings: settings,
                                                     operation: .engrave())

        #expect(toolpaths.count == 2)
    }
}
