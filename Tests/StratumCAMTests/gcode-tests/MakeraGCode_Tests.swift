//
//  MakeraGCode_Contour_Tests.swift
//  StratumCAM
//
//  Tests for SCMakeraGCodeEngine. The reference job below is meant to be reproduced in
//  Makera Studio so the two outputs can be compared line by line:
//
//    - 10x10 mm square, outside contour (climb, plunge entry, no lead-in/out, no tabs)
//    - 3.175 mm flat end mill, T1
//    - 0.1 mm stepdown, 1 mm total depth (Z0 = top of stock)
//    - 12000 RPM, feed 1200 mm/min, plunge 300 mm/min
//
//  The generated G-code is attached to the test run and also written to
//  `$TMPDIR/StratumCAM_square_10x10_outside.cnc` for diffing.
//

import Testing
import Foundation
@testable import StratumCAM

struct MakeraGCode_Contour_Tests {

    // MARK: - Fixtures

    private func squareContour() -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(10, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(10, 0), b: SIMD2<Double>(10, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(10, 10), b: SIMD2<Double>(0, 10)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, 10), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true)
    }

    private let tool = SC.ToolParams(name: "3.175mm Flat End Mill",
                                     type: .flatEndMill,
                                     diameter: 3.175,
                                     fluteLength: 12,
                                     number: 1)

    private let settings = SC.MachineSettings(
        cutting: SC.CuttingData(spindleSpeed: 12000, feedRate: 1200, plungeRate: 300, stepdown: 0.1),
        safeZ: 5.0,
        retractZ: 1.0,
        targetDepth: -1.0
    )

    private func makeToolpaths() throws -> [SC.OutputToolpath] {
        try SCEngine().generateToolpaths(
            from: [squareContour()],
            tool: tool,
            settings: settings,
            operation: .contour(side: .outside, direction: .climb, entry: .plunge,
                                leadIn: nil, leadOut: nil, tabs: [])
        )
    }

    private func makeGCode() throws -> (toolpaths: [SC.OutputToolpath], gcode: String) {
        let toolpaths = try makeToolpaths()
        let gcode = try SCMakeraGCodeEngine().generateGCode(from: toolpaths, settings: settings)

        // Dump for manual comparison with Makera Studio.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StratumCAM_square_10x10_outside.cnc")
        try? gcode.write(to: url, atomically: true, encoding: .utf8)
        print("G-code written to \(url.path)\n\(gcode)")

        return (toolpaths, gcode)
    }

    private func codeLines(_ gcode: String) -> [String] {
        gcode.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("(") }
    }

    /// Parses the numeric value of an axis word ("X-1.5") in a line, if present.
    private func value(_ axis: Character, in line: String) -> Double? {
        for word in line.split(separator: " ") where word.first == axis {
            return Double(word.dropFirst())
        }
        return nil
    }

    // MARK: - Tests

    @Test("Square contour: 10 passes of 0.1mm down to Z-1")
    func testPassCountAndDepth() throws {
        let (toolpaths, _) = try makeGCode()

        #expect(toolpaths.count == 1)
        #expect(toolpaths[0].passes.count == 10)
        #expect(abs(toolpaths[0].passes.last!.depthZ - (-1.0)) < 1e-6)
    }

    @Test("Header, tool change, spindle start and footer follow the Carvera post")
    func testHeaderAndFooter() throws {
        let (_, gcode) = try makeGCode()
        let code = codeLines(gcode)

        // Header
        #expect(Array(code.prefix(3)) == ["G90 G94", "G17", "G21"])

        // Tool change, then spindle start with external control, then work offset.
        let tool = try #require(code.firstIndex(of: "T1M6"))
        let spindle = try #require(code.firstIndex(of: "S12000 M3"))
        let offset = try #require(code.firstIndex(of: "G54"))
        #expect(tool < spindle)
        #expect(spindle < offset)
        #expect(code[spindle - 2] == "M400")
        #expect(code[spindle - 1] == "M851 S100")

        // Footer
        #expect(Array(code.suffix(5)) == ["M5", "M400", "M852", "G28", "M30"])
    }

    @Test("Tool list comment reports tool number, diameter and minimum Z")
    func testToolListComment() throws {
        let (_, gcode) = try makeGCode()
        let line = try #require(gcode.components(separatedBy: "\n").first { $0.hasPrefix("(T1 ") })

        #expect(line.contains("D=3.175"))
        #expect(line.contains("ZMIN=-1."))
    }

    @Test("Cutter path is the 10x10 square offset outward by the tool radius")
    func testOutsideOffsetBounds() throws {
        let (_, gcode) = try makeGCode()

        // Only look at cutting moves (G1), where the tool is at depth.
        var xs: [Double] = []
        var ys: [Double] = []
        var currentX: Double?
        var currentY: Double?
        for line in codeLines(gcode) {
            if let x = value("X", in: line) { currentX = x }
            if let y = value("Y", in: line) { currentY = y }
            if line.hasPrefix("G1"), let x = currentX, let y = currentY {
                xs.append(x)
                ys.append(y)
            }
        }

        let r = 3.175 / 2
        #expect(!xs.isEmpty)
        #expect(abs(xs.min()! - (-r)) < 1e-3)
        #expect(abs(xs.max()! - (10 + r)) < 1e-3)
        #expect(abs(ys.min()! - (-r)) < 1e-3)
        #expect(abs(ys.max()! - (10 + r)) < 1e-3)
    }

    @Test("Every pass is announced and Z never goes below the target depth")
    func testPassesAndZRange() throws {
        let (toolpaths, gcode) = try makeGCode()

        let passComments = gcode.components(separatedBy: "\n").filter { $0.hasPrefix("(--- Pass Depth:") }
        #expect(passComments.count == toolpaths[0].passes.count)

        let zs = codeLines(gcode).compactMap { value("Z", in: $0) }
        #expect(zs.min()! >= -1.0 - 1e-6)
        #expect(abs(zs.min()! - (-1.0)) < 1e-6)
    }

    @Test("Feed rates: plunge 300, cutting 1200")
    func testFeedRates() throws {
        let (_, gcode) = try makeGCode()
        let feeds = Set(codeLines(gcode).compactMap { value("F", in: $0) })

        #expect(feeds.contains(300))
        #expect(feeds.contains(1200))
    }

    @Test("Stock C1 mode accepts T1 and rejects T7")
    func testStockC1ToolLimit() throws {
        var options = SCMakeraGCodeEngine.Options()
        options.toolChangeMode = .stockC1

        let toolpaths = try makeToolpaths()
        #expect(throws: Never.self) {
            _ = try SCMakeraGCodeEngine(options: options).generateGCode(from: toolpaths, settings: settings)
        }

        var tool7 = tool
        tool7.number = 7
        var toolpath7 = toolpaths[0]
        toolpath7.tool = tool7
        #expect(throws: SCMakeraGCodeEngine.GenerationError.self) {
            _ = try SCMakeraGCodeEngine(options: options).generateGCode(from: [toolpath7], settings: settings)
        }
    }

    @Test("Empty toolpath list throws")
    func testNoToolpathsThrows() {
        #expect(throws: SCMakeraGCodeEngine.GenerationError.self) {
            _ = try SCMakeraGCodeEngine().generateGCode(from: [], settings: settings)
        }
    }
}
