//
//  File.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import StratumCAM
import SwiftDXF

class DemoEngraving: Demo {

    /// This will engravea line with one single pass
    func demoLine() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175)

        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                  plungeRate: 300.0,
                                                                  stepdown: 0.1),
                                          safeZ: 5.0,
                                          targetDepth: 0.1)

        let lineEntity = DXF.Entity.line(a: DXF.Point(0, 0),
                                         b: DXF.Point(20, 0),
                                         layer: "0",
                                         color: 7)
        let contour = SC.Contour(
            entities: [
                SC.Contour.Chained(entity: lineEntity, reversed: false)
            ],
            isClosed: false
        )

        return self.run(contour: contour, tool: tool, settings: settings, operation: .engrave)
    }

    /// Engraves the character "S" as a single continuous pass, built from two
    /// chained arcs of equal radius curving in opposite directions (the same
    /// construction a stroke font uses for the letter's two humps).
    func demoLetterS() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175)

        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                  plungeRate: 300.0,
                                                                  stepdown: 0.1),
                                          safeZ: 5.0,
                                          targetDepth: 1.0)

        let radius = 5.0

        // Lower hump: sweeps from (0, 0) to (0, 10), bulging right through (radius, 5).
        let lowerArc = DXF.Entity.arc(center: DXF.Point(0, radius),
                                      radius: radius,
                                      startDeg: 270.0,
                                      endDeg: 90.0,
                                      layer: "0",
                                      color: 7)

        // Upper hump: sweeps from (0, 10) to (0, 20), bulging left through (-radius, 15).
        // Defined the same way as the lower arc but reversed, so it continues on
        // from where the lower arc ends while curving the opposite way.
        let upperArc = DXF.Entity.arc(center: DXF.Point(0, radius * 3),
                                      radius: radius,
                                      startDeg: 90.0,
                                      endDeg: 270.0,
                                      layer: "0",
                                      color: 7)

        let contour = SC.Contour(
            entities: [
                SC.Contour.Chained(entity: lowerArc, reversed: false),
                SC.Contour.Chained(entity: upperArc, reversed: true)
            ],
            isClosed: false
        )

        return self.run(contour: contour, tool: tool, settings: settings, operation: .engrave)
    }

    // MARK: - Word

    /// Engraves the word "STRATUM" as a simple single-stroke font, one letter
    /// after another along the X axis. Each letter is built from one or more
    /// pen-plotter-style strokes; a stroke that can't be drawn without lifting
    /// the tool (e.g. the crossbar of an "A") becomes its own `SC.Contour`, so
    /// the whole word is a batch of contours run through the
    /// `run(contours:tool:settings:operation:)` overload in one call — the same
    /// way `demoMultipleHoles()` batches several drill points.
    ///
    /// Every letter is drawn inside a local 10 (wide) x 20 (tall) box with its
    /// baseline at y = 0, then shifted along X by `letterAdvance` per letter so
    /// the word reads left to right.
    func demoWordSTRATUM() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175)

        let settings = SC.MachineSettings(cutting: SC.CuttingData(feedRate: 1000.0,
                                                                  plungeRate: 300.0,
                                                                  stepdown: 0.1),
                                          safeZ: 5.0,
                                          targetDepth: 1.0)

        let letterAdvance = 14.0 // 10-wide letter box + 4 of spacing

        let letters: [(Double) -> [SC.Contour]] = [
            letterS, letterT, letterR, letterA, letterT, letterU, letterM
        ]

        var contours: [SC.Contour] = []
        for (index, letter) in letters.enumerated() {
            let xOffset = Double(index) * letterAdvance
            contours.append(contentsOf: letter(xOffset))
        }

        return self.run(contours: contours, tool: tool, settings: settings, operation: .engrave)
    }

    // MARK: - Letterforms
    // Each function returns one or more strokes (as separate `SC.Contour`s,
    // since a stroke the pen must lift between is a pen-up/pen-down break,
    // not a chained entity) for a single glyph drawn in a local 10x20 box
    // with its baseline at y = 0, shifted by `xOffset` along X.

    /// Reuses the same two-arc construction as `demoLetterS`, shifted so the
    /// glyph sits inside the shared [0, 10] letter box instead of [-5, 5].
    private func letterS(_ xOffset: Double) -> [SC.Contour] {
        let radius = 5.0
        let cx = xOffset + 5.0

        let lowerArc = DXF.Entity.arc(center: DXF.Point(cx, radius),
                                      radius: radius,
                                      startDeg: 270.0,
                                      endDeg: 90.0,
                                      layer: "0",
                                      color: 7)
        let upperArc = DXF.Entity.arc(center: DXF.Point(cx, radius * 3),
                                      radius: radius,
                                      startDeg: 90.0,
                                      endDeg: 270.0,
                                      layer: "0",
                                      color: 7)

        return [
            SC.Contour(entities: [
                SC.Contour.Chained(entity: lowerArc, reversed: false),
                SC.Contour.Chained(entity: upperArc, reversed: true)
            ], isClosed: false)
        ]
    }

    /// A crossbar and a stem, drawn as two separate pen-down strokes.
    private func letterT(_ xOffset: Double) -> [SC.Contour] {
        let bar = lineContour(xOffset + 0, 20, xOffset + 10, 20)
        let stem = lineContour(xOffset + 5, 20, xOffset + 5, 0)
        return [bar, stem]
    }

    /// A vertical stem, a chained bowl at the top, and a diagonal leg from the
    /// bowl down to the baseline — a simplified single-stroke "R".
    private func letterR(_ xOffset: Double) -> [SC.Contour] {
        let stem = lineContour(xOffset + 0, 0, xOffset + 0, 20)

        let bowl = SC.Contour(entities: [
            SC.Contour.Chained(entity: line(xOffset + 0, 20, xOffset + 8, 20), reversed: false),
            SC.Contour.Chained(entity: line(xOffset + 8, 20, xOffset + 8, 11), reversed: false),
            SC.Contour.Chained(entity: line(xOffset + 8, 11, xOffset + 0, 11), reversed: false)
        ], isClosed: false)

        let leg = lineContour(xOffset + 0, 11, xOffset + 9, 0)

        return [stem, bowl, leg]
    }

    /// Two diagonals chained into a peak, plus a separate horizontal crossbar.
    private func letterA(_ xOffset: Double) -> [SC.Contour] {
        let peak = SC.Contour(entities: [
            SC.Contour.Chained(entity: line(xOffset + 0, 0, xOffset + 5, 20), reversed: false),
            SC.Contour.Chained(entity: line(xOffset + 5, 20, xOffset + 10, 0), reversed: false)
        ], isClosed: false)

        let crossbar = lineContour(xOffset + 2.5, 8, xOffset + 7.5, 8)

        return [peak, crossbar]
    }

    /// A single chained polyline approximating a rounded-bottom "U".
    private func letterU(_ xOffset: Double) -> [SC.Contour] {
        let points: [(Double, Double)] = [
            (0, 20), (0, 5), (2, 0), (8, 0), (10, 5), (10, 20)
        ]
        return [polylineContour(points, xOffset: xOffset)]
    }

    /// A single chained zig-zag stem-to-stem "M".
    private func letterM(_ xOffset: Double) -> [SC.Contour] {
        let points: [(Double, Double)] = [
            (0, 0), (0, 20), (5, 8), (10, 20), (10, 0)
        ]
        return [polylineContour(points, xOffset: xOffset)]
    }

    // MARK: - Stroke helpers

    private func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> DXF.Entity {
        .line(a: DXF.Point(x1, y1), b: DXF.Point(x2, y2), layer: "0", color: 7)
    }

    /// Wraps a single straight line as a one-entity, open `SC.Contour`.
    private func lineContour(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> SC.Contour {
        SC.Contour(entities: [
            SC.Contour.Chained(entity: line(x1, y1, x2, y2), reversed: false)
        ], isClosed: false)
    }

    /// Chains a polyline of local-space points, offset along X, into a single
    /// open contour — one line entity per consecutive pair of points.
    private func polylineContour(_ points: [(Double, Double)], xOffset: Double) -> SC.Contour {
        var entities: [SC.Contour.Chained] = []
        for i in 0..<(points.count - 1) {
            let (x1, y1) = points[i]
            let (x2, y2) = points[i + 1]
            entities.append(SC.Contour.Chained(entity: line(xOffset + x1, y1, xOffset + x2, y2), reversed: false))
        }
        return SC.Contour(entities: entities, isClosed: false)
    }
}
