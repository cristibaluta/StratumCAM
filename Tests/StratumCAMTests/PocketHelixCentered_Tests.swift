//
//  PocketHelixCentered_Tests.swift
//  StratumCAM
//

import Testing
import CoreGraphics
import simd
@testable import StratumCAM

// Helix entry on a circular pocket cleared inside-out must spiral around the circle's
// center (the origin here), not off to one side.

struct PocketHelixCentered_Tests {

    private func circleContour(radius: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(geometry: .circle(center: SIMD2<Double>(0, 0), radius: radius), reversed: false)
        ], isClosed: true)
    }

    private func firstPass(angle: Double, depth: Double, pocketRadius: Double = 20) throws -> [SC.Waypoint] {
        let tool = SC.ToolParams(diameter: 6.0)
        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4),
                                          safeZ: 5.0,
                                          targetDepth: depth)
        let toolpaths = try SCEngine().generateToolpaths(
            from: [circleContour(radius: pocketRadius)],
            tool: tool,
            settings: settings,
            operation: .pocket(direction: .climb,
                               pattern: .concentric(direction: .insideOut),
                               entry: .helix(rampAngleDegrees: angle))
        )
        return try #require(toolpaths.first?.passes.first?.waypoints)
    }

    private func isArc(_ motion: SC.MotionType) -> Bool {
        if case .arcCW = motion { return true }
        if case .arcCCW = motion { return true }
        return false
    }

    @Test("Helix arcs are centered on the circle's center")
    func testHelixCenteredOnShapeCenter() throws {
        let waypoints = try firstPass(angle: 3.0, depth: -1.0)
        let descending = waypoints.filter { isArc($0.motion) && $0.position.z > -1.0 + 1e-9 }
        #expect(!descending.isEmpty)
        for waypoint in descending {
            switch waypoint.motion {
                case .arcCW(let c), .arcCCW(let c):
                    #expect(abs(c.x) < 1e-6 && abs(c.y) < 1e-6)
                default:
                    break
            }
        }
    }

    @Test("Helix reaches depth exactly at its start angle")
    func testHelixEndsAtStartPoint() throws {
        let waypoints = try firstPass(angle: 3.0, depth: -1.0)
        let startRapid = try #require(waypoints.first(where: { $0.motion == .rapid && abs($0.position.z) < 1e-9 }))
        let atDepth = try #require(waypoints.first(where: { isArc($0.motion) && abs($0.position.z + 1.0) < 1e-9 }))
        // First arc to reach full depth is the last helix step: back on the start point.
        #expect(abs(atDepth.position.x - startRapid.position.x) < 1e-6)
        #expect(abs(atDepth.position.y - startRapid.position.y) < 1e-6)
    }

    @Test("Ramp angle is never steeper than requested")
    func testHelixHonorsAngle() throws {
        let waypoints = try firstPass(angle: 3.0, depth: -1.0)
        var previous = try #require(waypoints.first(where: { $0.motion == .rapid && abs($0.position.z) < 1e-9 })).position
        let tanLimit = tan(3.0 * Double.pi / 180.0)
        for waypoint in waypoints where isArc(waypoint.motion) && waypoint.position.z > -1.0 - 1e-9 && waypoint.position.z < previous.z - 1e-12 {
            let dz = previous.z - waypoint.position.z
            let chord = hypot(waypoint.position.x - previous.x, waypoint.position.y - previous.y)
            #expect(dz / chord <= tanLimit * 1.05)
            previous = waypoint.position
        }
    }

    @Test("Helix radius is 95% of the tool radius, not the tiny first ring")
    func testHelixRadiusIsNearToolRadius() throws {
        let waypoints = try firstPass(angle: 3.0, depth: -1.0)
        let helix = waypoints.filter { isArc($0.motion) && $0.position.z > -1.0 + 1e-9 }
        #expect(!helix.isEmpty)
        for waypoint in helix {
            #expect(abs(hypot(Double(waypoint.position.x), Double(waypoint.position.y)) - 0.95 * 3.0) < 1e-6)
        }
    }

    @Test("Helix shrinks to fit a pocket too small for the full radius")
    func testHelixShrinksInSmallPocket() throws {
        // Pocket radius 4, tool radius 3: the tool center can only be 1mm from the center.
        let waypoints = try firstPass(angle: 3.0, depth: -1.0, pocketRadius: 4)
        let helix = waypoints.filter { isArc($0.motion) && $0.position.z > -1.0 + 1e-9 }
        #expect(!helix.isEmpty)
        for waypoint in helix {
            #expect(hypot(Double(waypoint.position.x), Double(waypoint.position.y)) <= 1.0 + 1e-6)
        }
    }

    @Test("Inside-out circles start at the helix radius and step outward, the last with a shorter step")
    func testCirclesGrowFromHelixRadiusToWall() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let stepover = SC.CuttingData().stepoverPercentage * tool.diameter // default 25% -> 1.5
        let oriented = engine.orientedForDirection(circleContour(radius: 20).linearizedSegments, side: .inside, direction: .climb)
        let rings = engine.pocketRings(from: oriented, tool: tool, stepoverPercentage: SC.CuttingData().stepoverPercentage)
        let stack = try #require(engine.centeredRings(offsetRings: rings, zones: [], toolRadius: 3.0, stepover: stepover))

        let radii: [Double] = stack.compactMap {
            if case .arc(_, let r, _, _, _)? = $0.first { return r }
            return nil
        }
        #expect(radii.count == stack.count)
        // First circle: 95% of the tool radius. Wall ring (tool-center path): 20 - 3 = 17.
        #expect(abs(radii[0] - 2.85) < 1e-6)
        #expect(abs(radii[radii.count - 1] - 17.0) < 1e-3)
        for k in 1..<radii.count {
            let step = radii[k] - radii[k - 1]
            #expect(step > 0 && step <= stepover + 1e-6, "step \(step) at ring \(k)")
            if k < radii.count - 1 {
                #expect(abs(step - stepover) < 1e-6, "only the last step may be shorter")
            }
        }
    }
}
