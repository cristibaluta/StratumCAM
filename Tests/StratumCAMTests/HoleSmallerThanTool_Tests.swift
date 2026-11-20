import Testing
import Foundation
import simd
@testable import StratumCAM

struct HoleSmallerThanTool_Tests {

    private func hole(radius: Double) -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .circle(center: SIMD2<Double>(0, 0), radius: radius), reversed: false)
        ], isClosed: true)
    }

    private let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300, stepdown: 1.0, stepoverPercentage: 0.25),
                                              safeZ: 5, targetDepth: -3)
    private let operation: SC.MachiningOperation = .pocket(direction: .climb,
                                                           pattern: .concentric(direction: .insideOut),
                                                           entry: .helix(rampAngleDegrees: 3))

    // A round hole narrower than the bit can't be cut: the pocket throws instead of tracing the wall.
    @Test func holeSmallerThanToolThrowsGeometryCollapsed() {
        #expect(throws: SC.Error.geometryCollapsed) {
            try SCEngine().generateToolpaths(from: [hole(radius: 1.0)],
                                             tool: SC.ToolParams(diameter: 3.175),
                                             settings: settings,
                                             operation: operation)
        }
    }

    // A hole wider than the bit still works.
    @Test func holeWiderThanToolBuildsToolpath() throws {
        let paths = try SCEngine().generateToolpaths(from: [hole(radius: 4.0)],
                                                     tool: SC.ToolParams(diameter: 3.175),
                                                     settings: settings,
                                                     operation: operation)
        #expect(!paths.isEmpty)
    }

    // The offset itself reports "fits nowhere" (no loops) for a circle smaller than the tool,
    // instead of an inverted circle.
    @Test func offsetOfCircleSmallerThanToolIsEmpty() {
        let engine = SCEngine()
        let segments = hole(radius: 1.0).linearizedSegments
        #expect(engine.offsetContours(segments, side: .inside, toolRadius: 1.5875, isClosed: true).isEmpty)
    }

    // MARK: - Inside contour

    private let insideContour: SC.MachiningOperation = .contour(side: .inside,
                                                                direction: .climb,
                                                                entry: .plunge,
                                                                leadIn: nil,
                                                                leadOut: nil,
                                                                tabs: [])

    // An inside contour on a round hole narrower than the bit throws instead of cutting the wall.
    @Test func insideContourOnHoleSmallerThanToolThrowsGeometryCollapsed() {
        #expect(throws: SC.Error.geometryCollapsed) {
            try SCEngine().generateToolpaths(from: [hole(radius: 1.0)],
                                             tool: SC.ToolParams(diameter: 3.175),
                                             settings: settings,
                                             operation: insideContour)
        }
    }

    // A hole wider than the bit is cut with the tool centre one tool radius inside the wall.
    @Test func insideContourOnHoleWiderThanToolStaysOneToolRadiusInside() throws {
        let tool = SC.ToolParams(diameter: 3.175)
        let paths = try SCEngine().generateToolpaths(from: [hole(radius: 4.0)],
                                                     tool: tool,
                                                     settings: settings,
                                                     operation: insideContour)
        #expect(!paths.isEmpty)
        let maxR = paths.flatMap { $0.passes.flatMap { $0.waypoints } }
            .map { hypot($0.position.x, $0.position.y) }.max() ?? 0
        #expect(abs(maxR - (4.0 - tool.diameter / 2.0)) < 1e-3)
    }
}
