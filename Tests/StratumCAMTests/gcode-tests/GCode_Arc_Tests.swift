//
//  GCode_Arc_Tests.swift
//  StratumCAM
//
//  Regression tests for G02/G03 I/J: they are offsets from the arc START to its center.
//  Each emitted arc must be geometrically consistent -- start and end equidistant from
//  the center it implies -- which a wrong (end-relative) I/J breaks for any partial arc.
//

import Testing
import Foundation
import StratumCAM

struct GCode_Arc_Tests {

    private let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000, plungeRate: 300),
                                              safeZ: 5,
                                              targetDepth: -0.1)

    private func word(_ letter: Character, in line: String) -> Double? {
        for part in line.split(separator: " ") where part.first == letter {
            return Double(part.dropFirst())
        }
        return nil
    }

    /// Returns the radius error (|start-center| vs |end-center|) of every arc line.
    private func arcRadiusErrors(in gcode: String) -> [Double] {
        var x = 0.0, y = 0.0
        var errors: [Double] = []
        for line in gcode.split(separator: "\n").map(String.init) {
            let isArc = line.hasPrefix("G02") || line.hasPrefix("G03") || line.hasPrefix("G2 ") || line.hasPrefix("G3 ")
            let nx = word("X", in: line) ?? x
            let ny = word("Y", in: line) ?? y
            if isArc, let i = word("I", in: line), let j = word("J", in: line) {
                let cx = x + i, cy = y + j
                errors.append(abs(hypot(x - cx, y - cy) - hypot(nx - cx, ny - cy)))
            }
            if line.hasPrefix("G0") || line.hasPrefix("G1") || line.hasPrefix("G2") || line.hasPrefix("G3") {
                x = nx
                y = ny
            }
        }
        return errors
    }

    private func toolpaths(for arc: SC.Geometry, reversed: Bool) throws -> [SC.OutputToolpath] {
        let contour = SC.Contour(entities: [.init(geometry: arc, reversed: reversed)], isClosed: false)
        return try SCEngine().generateToolpaths(from: [contour],
                                                tool: SC.ToolParams(diameter: 3),
                                                settings: settings,
                                                operation: .engrave)
    }

    @Test("Generic engine: CCW quarter arc has I/J relative to the arc start")
    func testCCWQuarterArc() throws {
        // Center (0,0), r=10, (10,0) -> (0,10) CCW: I = -10, J = 0
        let paths = try toolpaths(for: .arc(center: SIMD2(0, 0), radius: 10, startDeg: 0, endDeg: 90), reversed: false)
        let gcode = SCGCodeEngine().generateGCode(from: paths, settings: settings)

        #expect(gcode.contains("G03 X0.000 Y10.000 Z-0.100 I-10.000 J0.000"))
        #expect(arcRadiusErrors(in: gcode).allSatisfy { $0 < 1e-3 })
    }

    @Test("Generic engine: CW (reversed) quarter arc has I/J relative to the arc start")
    func testCWQuarterArc() throws {
        // Reversed: (0,10) -> (10,0) CW around (0,0): I = 0, J = -10
        let paths = try toolpaths(for: .arc(center: SIMD2(0, 0), radius: 10, startDeg: 0, endDeg: 90), reversed: true)
        let gcode = SCGCodeEngine().generateGCode(from: paths, settings: settings)

        #expect(gcode.contains("G02 X10.000 Y0.000 Z-0.100 I0.000 J-10.000"))
        #expect(arcRadiusErrors(in: gcode).allSatisfy { $0 < 1e-3 })
    }

    @Test("Generic engine: off-origin arcs in multi-pass contours stay consistent")
    func testOffOriginMultiPassArcs() throws {
        let paths = try toolpaths(for: .arc(center: SIMD2(37.5, -12.25), radius: 6.5, startDeg: 200, endDeg: 310), reversed: false)
        let gcode = SCGCodeEngine().generateGCode(from: paths, settings: settings)
        let errors = arcRadiusErrors(in: gcode)

        #expect(!errors.isEmpty)
        #expect(errors.allSatisfy { $0 < 2e-3 })
    }

    @Test("Generic engine never writes negative zero")
    func testNoNegativeZero() throws {
        let paths = try toolpaths(for: .arc(center: SIMD2(0, 0), radius: 10, startDeg: 0, endDeg: 90), reversed: false)
        let gcode = SCGCodeEngine().generateGCode(from: paths, settings: settings)

        #expect(!gcode.contains("-0.000"))
    }

    @Test("Makera engine agrees: arcs are start-relative too")
    func testMakeraArcs() throws {
        let paths = try toolpaths(for: .arc(center: SIMD2(37.5, -12.25), radius: 6.5, startDeg: 200, endDeg: 310), reversed: false)
        let gcode = try SCMakeraGCodeEngine().generateGCode(from: paths, settings: settings)
        let errors = arcRadiusErrors(in: gcode)

        #expect(!errors.isEmpty)
        #expect(errors.allSatisfy { $0 < 2e-3 })
    }
}
