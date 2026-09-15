//
//  GCode_Boring_Tests.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Testing
import SwiftDXF
@testable import StratumCAM

// Covers Step 2C.2's dwellTime half: boring's dwell lives on the operation itself, not
// MachineSettings, and is emitted at G-code generation time right after the circular
// interpolation's last arc -- before any shift-off-center or retract move.

struct GCode_Boring_Tests {

    @Test("Boring emits a dwell after the final arc and before the retract")
    func testBoringDwellIsEmittedAfterFinalArc() throws {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(
            cutting: SC.CuttingData(spindleSpeed: 10000.0, feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0),
            safeZ: 5.0,
            targetDepth: 8.0
        )

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(10, 20), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = try SCEngine().generateToolpaths(
            from: [contour],
            tool: tool,
            settings: settings,
            operation: .boring(targetDiameter: 10.0, dwellTime: 0.5, shiftRetract: false)
        )

        let gcode = SCGCodeEngine().generateGCode(from: toolpaths, settings: settings)
        let lines = gcode.components(separatedBy: "\n")

        // Final arc: from (5, 20) back to the bore's edge (15, 20) at Z-8.
        let finalArcIndex = lines.firstIndex(where: { $0.contains("G03 X15.000 Y20.000 Z-8.000") })
        let dwellIndex = lines.firstIndex(where: { $0 == "G04 P0.500 (Boring dwell)" })
        let finalRetractIndex = lines.lastIndex(where: { $0 == "G00 Z5.000" })

        #expect(finalArcIndex != nil, "Test Failed: final arc should be present in G-code")
        #expect(dwellIndex != nil, "Test Failed: boring dwell should be emitted")
        #expect(finalRetractIndex != nil, "Test Failed: final retract should be present in G-code")

        if let finalArcIndex, let dwellIndex, let finalRetractIndex {
            #expect(finalArcIndex < dwellIndex, "Test Failed: dwell must occur after the final arc")
            #expect(dwellIndex < finalRetractIndex, "Test Failed: dwell must occur before the final retract")
        }
    }

    @Test("Boring without a dwellTime does not emit a G04 command")
    func testBoringWithoutDwellTimeDoesNotEmitDwell() throws {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(
            cutting: SC.CuttingData(spindleSpeed: 9000.0, feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0),
            safeZ: 5.0,
            targetDepth: 5.0
        )

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(5, 6), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = try SCEngine().generateToolpaths(
            from: [contour],
            tool: tool,
            settings: settings,
            operation: .boring(targetDiameter: 8.0, dwellTime: nil, shiftRetract: false)
        )

        let gcode = SCGCodeEngine().generateGCode(from: toolpaths, settings: settings)

        #expect(!gcode.contains("G04"), "Test Failed: G04 should not be emitted when dwellTime is nil")
    }

    @Test("Boring dwell still lands right after the final arc when shiftRetract also inserts a move")
    func testBoringDwellLandsBeforeShiftMoveWhenBothAreOn() throws {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0) // tool radius 3.0
        let settings = SC.MachineSettings(
            cutting: SC.CuttingData(spindleSpeed: 9000.0, feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0),
            safeZ: 5.0,
            targetDepth: 8.0
        )

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(0, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let toolpaths = try SCEngine().generateToolpaths(
            from: [contour],
            tool: tool,
            settings: settings,
            operation: .boring(targetDiameter: 10.0, dwellTime: 1.0, shiftRetract: true) // bore radius 5.0
        )

        let gcode = SCGCodeEngine().generateGCode(from: toolpaths, settings: settings)
        let lines = gcode.components(separatedBy: "\n")

        // Final arc back to the bore's edge (5, 0), then dwell, then the shift move
        // inward to (2, 0) -- tool radius 3.0 inside the 5.0 bore radius -- then retract.
        let finalArcIndex = lines.firstIndex(where: { $0.contains("G03 X5.000 Y0.000 Z-8.000") })
        let dwellIndex = lines.firstIndex(where: { $0 == "G04 P1.000 (Boring dwell)" })
        let shiftIndex = lines.firstIndex(where: { $0.contains("G01 X2.000 Y0.000 Z-8.000") })
        let finalRetractIndex = lines.lastIndex(where: { $0 == "G00 Z5.000" })

        #expect(finalArcIndex != nil, "Test Failed: final arc should be present in G-code")
        #expect(dwellIndex != nil, "Test Failed: boring dwell should be emitted")
        #expect(shiftIndex != nil, "Test Failed: shift-off-center move should be present in G-code")
        #expect(finalRetractIndex != nil, "Test Failed: final retract should be present in G-code")

        if let finalArcIndex, let dwellIndex, let shiftIndex, let finalRetractIndex {
            #expect(finalArcIndex < dwellIndex, "Test Failed: dwell must occur after the final arc")
            #expect(dwellIndex < shiftIndex, "Test Failed: dwell must occur before the shift-off-center move, not after it")
            #expect(shiftIndex < finalRetractIndex, "Test Failed: shift-off-center move must occur before the final retract")
        }
    }

    @Test("A dwellTime of exactly zero does not emit a G04 command")
    func testBoringZeroDwellTimeDoesNotEmitDwell() throws {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(
            cutting: SC.CuttingData(spindleSpeed: 9000.0, feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0),
            safeZ: 5.0,
            targetDepth: 5.0
        )

        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(5, 6), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        // A zero dwellTime carries no useful instruction for the controller -- same
        // "dwell > 0" guard drilling's own G04 emission already applies.
        let toolpaths = try SCEngine().generateToolpaths(
            from: [contour],
            tool: tool,
            settings: settings,
            operation: .boring(targetDiameter: 8.0, dwellTime: 0.0, shiftRetract: false)
        )

        let gcode = SCGCodeEngine().generateGCode(from: toolpaths, settings: settings)

        #expect(!gcode.contains("G04"), "Test Failed: G04 should not be emitted when dwellTime is exactly zero")
    }

    @Test("Each hole in a batch of bores gets its own independent dwell")
    func testBoringBatchOfHolesEachGetsOwnDwell() throws {
        let tool = SC.ToolParams(type: .flatEndMill, diameter: 6.0)
        let settings = SC.MachineSettings(
            cutting: SC.CuttingData(spindleSpeed: 9000.0, feedRate: 1000.0, plungeRate: 200.0, stepdown: 1.0),
            safeZ: 5.0,
            targetDepth: 8.0
        )

        let contours = [(0.0, 0.0), (20.0, 0.0)].map { x, y in
            SC.Contour(entities: [
                .init(entity: .point(at: DXF.Point(x, y), layer: "0", color: 7), reversed: false)
            ], isClosed: false)
        }

        let toolpaths = try SCEngine().generateToolpaths(
            from: contours,
            tool: tool,
            settings: settings,
            operation: .boring(targetDiameter: 10.0, dwellTime: 0.25, shiftRetract: false)
        )

        let gcode = SCGCodeEngine().generateGCode(from: toolpaths, settings: settings)
        let dwellCount = gcode.components(separatedBy: "G04 P0.250 (Boring dwell)").count - 1

        #expect(dwellCount == 2, "Test Failed: expected one dwell per hole in the batch, got \(dwellCount)")
    }
}
