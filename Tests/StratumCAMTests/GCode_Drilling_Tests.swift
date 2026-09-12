//
//  GCode.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Testing
import SwiftDXF
@testable import StratumCAM

struct GCode_Drilling_Tests {

    @Test("Drilling emits a dwell after the final peck and before the final retract")
    func testDrillingDwellIsEmittedAfterFinalPeck() {
        let tool = SC.ToolParams(
            type: .drill,
            diameter: 4.0,
            stepdown: 1.0,
            spindleSpeed: 9000.0
        )

        let settings = SC.MachineSettings(
            feedRate: 1000.0,
            plungeRate: 200.0,
            spindleSpeed: 12000.0,
            safeZ: 5.0,
            retractZ: 1.0,
            targetDepth: 8.0,
            dwell: 0.75
        )

        let contour = SC.Contour(entities: [
            .init(
                entity: .point(
                    at: DXF.Point(10, 20),
                    layer: "0",
                    color: 7
                ),
                reversed: false
            )
        ], isClosed: false)

        let toolpaths = SCEngine().generateToolpaths(
            from: [contour],
            tool: tool,
            settings: settings,
            operation: .drilling(peckDepth: 4.0)
        )

        let gcode = SCGCodeEngine().generateGCode(
            from: toolpaths,
            settings: settings
        )

        let lines = gcode.components(separatedBy: "\n")

        let finalPeckIndex = lines.firstIndex(where: {
            $0.contains("G01 X10.000 Y20.000 Z-8.000")
        })

        let dwellIndex = lines.firstIndex(where: {
            $0 == "G04 P0.750 (Drilling dwell)"
        })

        let finalRetractIndex = lines.lastIndex(where: {
            $0 == "G00 Z5.000"
        })

        #expect(
            finalPeckIndex != nil,
            "Test Failed: final peck should be present in G-code"
        )

        #expect(
            dwellIndex != nil,
            "Test Failed: drilling dwell should be emitted"
        )

        #expect(
            finalRetractIndex != nil,
            "Test Failed: final retract should be present in G-code"
        )

        if let finalPeckIndex,
           let dwellIndex,
           let finalRetractIndex {

            #expect(
                finalPeckIndex < dwellIndex,
                "Test Failed: dwell must occur after the final peck"
            )

            #expect(
                dwellIndex < finalRetractIndex,
                "Test Failed: dwell must occur before the final retract"
            )
        }
    }

    @Test("Drilling without dwell does not emit a G04 command")
    func testDrillingWithoutDwellDoesNotEmitDwell() {
        let tool = SC.ToolParams(
            type: .drill,
            diameter: 3.0,
            stepdown: 1.0,
            spindleSpeed: 9000.0
        )

        let settings = SC.MachineSettings(
            feedRate: 1000.0,
            plungeRate: 200.0,
            safeZ: 5.0,
            targetDepth: 5.0
        )

        let contour = SC.Contour(entities: [
            .init(
                entity: .point(
                    at: DXF.Point(5, 6),
                    layer: "0",
                    color: 7
                ),
                reversed: false
            )
        ], isClosed: false)

        let toolpaths = SCEngine().generateToolpaths(
            from: [contour],
            tool: tool,
            settings: settings,
            operation: .drilling(peckDepth: nil)
        )

        let gcode = SCGCodeEngine().generateGCode(
            from: toolpaths,
            settings: settings
        )

        #expect(
            !gcode.contains("G04"),
            "Test Failed: G04 should not be emitted when drilling dwell is nil"
        )
    }

    @Test("Drilling uses the tool-specific spindle speed")
    func testDrillingUsesToolSpecificSpindleSpeed() {
        let tool = SC.ToolParams(
            type: .drill,
            diameter: 5.0,
            stepdown: 1.0,
            spindleSpeed: 8500.0
        )

        let settings = SC.MachineSettings(
            feedRate: 1000.0,
            plungeRate: 200.0,
            spindleSpeed: 12000.0,
            safeZ: 5.0,
            targetDepth: 4.0
        )

        let contour = SC.Contour(entities: [
            .init(
                entity: .point(
                    at: DXF.Point(15, 25),
                    layer: "0",
                    color: 7
                ),
                reversed: false
            )
        ], isClosed: false)

        let toolpaths = SCEngine().generateToolpaths(
            from: [contour],
            tool: tool,
            settings: settings,
            operation: .drilling(peckDepth: nil)
        )

        let gcode = SCGCodeEngine().generateGCode(
            from: toolpaths,
            settings: settings
        )

        #expect(
            gcode.contains("M03 S8500 (Drilling spindle speed)"),
            "Test Failed: drilling should select the tool-specific spindle speed"
        )
    }

    @Test("Drilling falls back to machine spindle speed when the tool has no spindle override")
    func testDrillingFallsBackToMachineSpindleSpeed() {
        let tool = SC.ToolParams(
            type: .drill,
            diameter: 3.0,
            stepdown: 1.0
        )

        let settings = SC.MachineSettings(
            feedRate: 1000.0,
            plungeRate: 200.0,
            spindleSpeed: 11000.0,
            safeZ: 5.0,
            targetDepth: 4.0
        )

        let contour = SC.Contour(entities: [
            .init(
                entity: .point(
                    at: DXF.Point(1, 2),
                    layer: "0",
                    color: 7
                ),
                reversed: false
            )
        ], isClosed: false)

        let toolpaths = SCEngine().generateToolpaths(
            from: [contour],
            tool: tool,
            settings: settings,
            operation: .drilling(peckDepth: nil)
        )

        let gcode = SCGCodeEngine().generateGCode(
            from: toolpaths,
            settings: settings
        )

        #expect(
            gcode.contains("M03 S11000 (Spindle On)"),
            "Test Failed: drilling without a tool spindle override should use machine spindle speed"
        )

        #expect(
            !gcode.contains("Drilling spindle speed"),
            "Test Failed: no redundant drilling spindle command should be emitted"
        )
    }
}
