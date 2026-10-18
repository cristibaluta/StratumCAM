//
//  DegenerateArc_Tests.swift
//  StratumCAM
//
//  A zero-length arc (end point == start point) is read by a controller as a full circle.
//  They must be dropped before reaching the G-code, and arcs shorter than the G-code
//  resolution (0.001) must be written as lines, because start and end would print identically.
//

import Testing
import Foundation
@testable import StratumCAM

struct DegenerateArc_Tests {

    private let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300),
                                              safeZ: 5,
                                              targetDepth: -1)

    private func toolpath(_ waypoints: [SC.Waypoint]) -> SC.OutputToolpath {
        SC.OutputToolpath(operation: .engrave,
                          tool: SC.ToolParams(diameter: 3),
                          settings: settings,
                          passes: [SC.ToolpathPass(passIndex: 0, depthZ: -1, waypoints: waypoints)])
    }

    private func wp(_ x: Double, _ y: Double, _ z: Double, _ motion: SC.MotionType) -> SC.Waypoint {
        SC.Waypoint(position: SIMD3(x, y, z), motion: motion, feedRate: 1000)
    }

    private func arcLines(_ gcode: String) -> [String] {
        gcode.split(separator: "\n").map(String.init).filter {
            $0.hasPrefix("G2 ") || $0.hasPrefix("G3 ") || $0.hasPrefix("G02") || $0.hasPrefix("G03")
        }
    }

    // MARK: - Segment

    @Test("Degenerate segments: zero-length arcs and lines, but not full circles")
    func testIsDegenerate() {
        let zeroArc = SC.Segment.arc(center: CGPoint(x: 0, y: 0), radius: 5, startAngle: 1, endAngle: 1, isCCW: true)
        let tinyArc = SC.Segment.arc(center: CGPoint(x: 0, y: 0), radius: 5, startAngle: 1, endAngle: 1 + 1e-8, isCCW: true)
        let fullCircle = SC.Segment.arc(center: CGPoint(x: 0, y: 0), radius: 5, startAngle: 0, endAngle: 2 * .pi, isCCW: true)
        let quarter = SC.Segment.arc(center: CGPoint(x: 0, y: 0), radius: 5, startAngle: 0, endAngle: .pi / 2, isCCW: true)
        let point = SC.Segment.line(start: CGPoint(x: 3, y: 3), end: CGPoint(x: 3, y: 3))
        let line = SC.Segment.line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 0))

        #expect(zeroArc.isDegenerate)
        #expect(tinyArc.isDegenerate)
        #expect(point.isDegenerate)
        #expect(!fullCircle.isDegenerate)
        #expect(!quarter.isDegenerate)
        #expect(!line.isDegenerate)
        #expect([zeroArc, line, tinyArc, quarter].removingDegenerate == [line, quarter])
    }

    @Test("A zero-sweep arc entity does not survive linearization")
    func testZeroSweepArcDropped() {
        // Arc from 270° to 270° around (10, 5): a zero-length arc at (10, 0), between two lines.
        let contour = SC.Contour(
            entities: [
                .init(entity: .line(a: SIMD2(0, 0), b: SIMD2(10, 0)), reversed: false),
                .init(entity: .arc(center: SIMD2(10, 5), radius: 5, startDeg: 270, endDeg: 270), reversed: false),
                .init(entity: .line(a: SIMD2(10, 0), b: SIMD2(20, 0)), reversed: false)
            ],
            isClosed: false
        )

        let segments = contour.linearizedSegments
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { if case .line = $0 { return true } else { return false } })
    }

    @Test("A bulge on a near-duplicate polyline vertex does not leave a micro arc")
    func testMicroBulgeArcDropped() {
        let contour = SC.Contour(
            entities: [.init(entity: .polyline(vertices: [.init(SIMD2(0, 0)),
                                                          .init(SIMD2(10, 0), bulge: 1),
                                                          .init(SIMD2(10, 1e-7)),
                                                          .init(SIMD2(10, 10))],
                                               closed: false),
                             reversed: false)],
            isClosed: false
        )

        #expect(contour.linearizedSegments.allSatisfy { !$0.isDegenerate })
        #expect(contour.linearizedSegments.count == 2)
    }

    // MARK: - End to end

    @Test("A contour with a zero-length arc never produces a full-circle G2/G3, in either engine")
    func testNoFullCircleFromZeroLengthArc() throws {
        let contour = SC.Contour(
            entities: [
                .init(entity: .line(a: SIMD2(0, 0), b: SIMD2(10, 0)), reversed: false),
                .init(entity: .arc(center: SIMD2(10, 5), radius: 5, startDeg: 270, endDeg: 270), reversed: false),
                .init(entity: .line(a: SIMD2(10, 0), b: SIMD2(20, 0)), reversed: false)
            ],
            isClosed: false
        )
        let paths = try SCEngine().generateToolpaths(from: [contour],
                                                     tool: SC.ToolParams(diameter: 3),
                                                     settings: settings,
                                                     operation: .engrave)

        #expect(arcLines(try SCMakeraGCodeEngine().generateGCode(from: paths, settings: settings)).isEmpty)
        #expect(arcLines(SCGCodeEngine().generateGCode(from: paths, settings: settings)).isEmpty)
    }

    // MARK: - G-code resolution

    private let tinyArc: [SC.Waypoint] = [
        SC.Waypoint(position: SIMD3(0, 0, 5), motion: .rapid, feedRate: 1000),
        SC.Waypoint(position: SIMD3(0, 0, -1), motion: .linear, feedRate: 300),
        // 0.0002 mm long: start and end both print as 0.000
        SC.Waypoint(position: SIMD3(0.0002, 0, -1), motion: .arcCCW(center: CGPoint(x: 0.0001, y: 5)), feedRate: 1000),
        SC.Waypoint(position: SIMD3(10, 0, -1), motion: .linear, feedRate: 1000)
    ]

    @Test("Makera: an arc shorter than the output resolution is written as a line")
    func testMakeraSubResolutionArc() throws {
        let gcode = try SCMakeraGCodeEngine().generateGCode(from: [toolpath(tinyArc)], settings: settings)
        #expect(arcLines(gcode).isEmpty)
    }

    @Test("Generic: an arc shorter than the output resolution is written as a line")
    func testGenericSubResolutionArc() {
        let gcode = SCGCodeEngine().generateGCode(from: [toolpath(tinyArc)], settings: settings)
        #expect(arcLines(gcode).isEmpty)
        #expect(gcode.contains("G01 X0.000 Y0.000 Z-1.000"))
    }

    @Test("A deliberate full circle (end exactly at start) is still written as an arc")
    func testDeliberateFullCircleKept() throws {
        let circle: [SC.Waypoint] = [
            wp(0, 0, 5, .rapid),
            wp(0, 0, -1, .linear),
            wp(0, 0, -1, .arcCCW(center: CGPoint(x: 0, y: 5)))
        ]

        #expect(arcLines(try SCMakeraGCodeEngine().generateGCode(from: [toolpath(circle)], settings: settings)).count == 1)
        #expect(arcLines(SCGCodeEngine().generateGCode(from: [toolpath(circle)], settings: settings)).count == 1)
    }

    @Test("A normal short arc is untouched")
    func testNormalArcUntouched() throws {
        let arc: [SC.Waypoint] = [
            wp(0, 0, 5, .rapid),
            wp(0, 0, -1, .linear),
            wp(5, 5, -1, .arcCCW(center: CGPoint(x: 0, y: 5)))
        ]

        #expect(arcLines(try SCMakeraGCodeEngine().generateGCode(from: [toolpath(arc)], settings: settings)).count == 1)
        #expect(arcLines(SCGCodeEngine().generateGCode(from: [toolpath(arc)], settings: settings)).count == 1)
    }
}
