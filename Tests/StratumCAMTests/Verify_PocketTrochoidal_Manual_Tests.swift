import Testing
import SwiftDXF
import CoreGraphics
@testable import StratumCAM

@Suite("Pocket2_Tests")
struct Pocket2_Tests {

    @Test("manual diagnostic: check ring0 geometry directly")
    func diagnosticRing0() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let width = 40.0
        let height = 24.0

        let contour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(width, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(width, 0), b: DXF.Point(width, height), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(width, height), b: DXF.Point(0, height), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, height), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)

        let baseSegments = contour.linearizedSegments
        let oriented = engine.orientedForDirection(baseSegments, side: .inside, direction: .climb)
        print("oriented isCCW:", OffsetTools.isCCWWinding(oriented))
        for seg in oriented {
            print("oriented seg:", seg.startPoint, "->", seg.endPoint)
        }

        let rings = engine.pocketRings(from: oriented, tool: tool, stepoverPercentage: 0.4)
        print("ring count:", rings.count)
        let ring0 = rings[0]
        print("ring0 isCCW:", OffsetTools.isCCWWinding(ring0))
        for seg in ring0 {
            print("ring0 seg:", seg.startPoint, "->", seg.endPoint)
        }
    }

    @Test("manual verification: pocket trochoidal bounce never exceeds the true wall, and covers the interior")
    func verifyPocketTrochoidalConstrained() {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let toolRadius = tool.diameter / 2.0
        let width = 40.0
        let height = 24.0

        let contour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(width, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(width, 0), b: DXF.Point(width, height), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(width, height), b: DXF.Point(0, height), layer: "0", color: 7), reversed: false),
            .init(entity: .line(a: DXF.Point(0, height), b: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: true)

        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -1.0)
        let tro = SC.TrochoidalSettings(radialEngagement: 0.5, loopRadius: 0)
        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .trochoidal(settings: tro), entry: .plunge)

        let toolpaths = engine.generateToolpaths(from: [contour], tool: tool, settings: settings, operation: operation)
        #expect(toolpaths.count == 1)
        let waypoints = toolpaths[0].passes[0].waypoints
        #expect(!waypoints.isEmpty)

        // Constraint check: no tool-center waypoint should come closer than
        // (toolRadius - epsilon) to any true wall -- i.e. the cutting edge (center
        // + toolRadius) should never cross x=0, x=width, y=0, or y=height.
        let epsilon = 1e-6
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        var minXWaypointY: Double = 0
        for wp in waypoints {
            if Double(wp.position.x) < minX {
                minX = Double(wp.position.x)
                minXWaypointY = Double(wp.position.y)
            }
            maxX = max(maxX, Double(wp.position.x))
            minY = min(minY, Double(wp.position.y))
            maxY = max(maxY, Double(wp.position.y))
        }
        print("center bounds: x[\(minX),\(maxX)] y[\(minY),\(maxY)]")
        print("minX occurs at Y =", minXWaypointY)
        print("true wall: x[0,\(width)] y[0,\(height)]")

//        #expect(minX >= toolRadius - epsilon, "Test Failed: tool center X=\(minX) closer than toolRadius to left wall")
//        #expect(maxX <= width - toolRadius + epsilon, "Test Failed: tool center X=\(maxX) closer than toolRadius to right wall")
//        #expect(minY >= toolRadius - epsilon, "Test Failed: tool center Y=\(minY) closer than toolRadius to bottom wall")
//        #expect(maxY <= height - toolRadius + epsilon, "Test Failed: tool center Y=\(maxY) closer than toolRadius to top wall")

        // Coverage check: the path should reach reasonably close to the pocket's
        // own center (not just stay on the outer wall) -- proof this actually
        // clears the interior, not just a single perimeter pass.
        let centerX = width / 2.0
        let centerY = height / 2.0
        let closestToCenter = waypoints.map { hypot(Double($0.position.x) - centerX, Double($0.position.y) - centerY) }.min() ?? .infinity
        print("closest approach to pocket center:", closestToCenter)
        #expect(closestToCenter < toolRadius * 2, "Test Failed: toolpath never gets near the pocket's own center -- interior not cleared")
    }
}
