//
//  SCGCodeEngine.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 10.09.2026.
//

import Foundation
import CoreGraphics

public struct SCGCodeEngine {

    public struct Options: Sendable, Equatable {

        /// Seconds to wait after every spindle start or speed change before the first move
        /// (`G04 P`). 0 turns the wait off.
        public var spindleWarmUpSeconds: Double = 3.0

        /// Air blast for chip clearing: `M7` once the spindle is up, `M9` before it stops.
        /// The same codes Makera Studio writes for every toolpath.
        public var airAssist: Bool = true

        public init() {}
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Converts generated toolpaths into standard CNC G-code instructions.
    ///
    /// The result is one self-contained SECTION, meant to be stitched with others by the caller
    /// (the tool change, `T<n> M6`, goes in front of it). It leaves the machine in a known
    /// state, runs the toolpaths, and leaves it safe: tool clear of the work, air off, spindle off.
    ///
    /// It does NOT write program-level codes: no `%` tape markers, no `M30`, no park (`G28`).
    /// An `M30` in the middle of a stitched program ends the job after the first section.
    /// Whoever stitches the sections writes those once, at the end: see `programFooter`.
    public func generateGCode(from toolpaths: [SC.OutputToolpath], settings: SC.MachineSettings) -> String {

        var lines: [String] = []

        // Known modal state. Each section re-asserts it, so no section depends on what ran
        // before it (a resumed job, a hand-edited file, whatever the machine was left in).
        // Same set as Makera's own Carvera post; G40/G49/G80 are left out on purpose: the
        // Carvera applies the tool length offset after M6, and G49 could cancel it.
        lines.append("G21 (Units: mm)")
        lines.append("G90 (Absolute Distance Mode)")
        lines.append("G94 (Feed per Minute)")
        lines.append("G17 (XY Plane Selection)")
        lines.append("G54 (Work Coordinate System 1)")
        let safeZText = String(format: "%.3f", settings.safeZ)
        lines.append("G00 Z\(safeZText) (Move to Safe Z)")

        // What the machine already has from the lines written so far: a word is only written
        // when its value changes. A section starts after a tool change, so nothing is known
        // except the safe Z just written.
        var modal = ModalState(z: safeZText)

        // Spindle: start at the speed the first toolpath needs, then wait for it to get there.
        var currentSpindleSpeed = toolpaths.first.map { Self.spindleSpeed(for: $0, machineWide: settings) }
            ?? settings.cutting.spindleSpeed
        lines.append("M03 S\(Int(currentSpindleSpeed)) (Spindle On)")
        appendWarmUp(to: &lines)

        if options.airAssist {
            lines.append("M7 (Air Assist On)")
        }

        // Toolpaths
        for toolpath in toolpaths {

            let isDrilling: Bool = {
                if case .drilling = toolpath.operation {
                    return true
                }
                return false
            }()

            // Step 2C.2: boring's dwell lives on the operation itself (`dwellTime`), not
            // on `MachineSettings.dwell` the way drilling's does, since it's specific to
            // this one bore rather than a machine-wide default.
            let boringDwellTime: Double? = {
                if case .boring(_, let dwellTime, _) = toolpath.operation {
                    return dwellTime
                }
                return nil
            }()

            // Step 1.5 intentionally handles only the drilling spindle override. Each
            // toolpath carries its own `settings.cutting.spindleSpeed` (set per-operation
            // when the toolpath was generated); if that differs from the speed the spindle is
            // already running at, emit an explicit override. Tool changes
            // (`M6`) and general per-tool spindle management remain a Track 4.1 concern.
            if isDrilling,
               abs(toolpath.settings.cutting.spindleSpeed - currentSpindleSpeed) > 0.000_001 {

                currentSpindleSpeed = toolpath.settings.cutting.spindleSpeed
                lines.append(
                    "M03 S\(Int(currentSpindleSpeed)) (Drilling spindle speed)"
                )
                appendWarmUp(to: &lines)
            }

            // I/J are relative to where the arc starts, i.e. the previous waypoint.
            var previousPosition: SIMD3<Double>?

            for pass in toolpath.passes {

                lines.append("(--- Pass Depth: \(pass.depthZ) ---)")

                // Step 2C.2: boring's dwell happens at the bottom of the bore -- right
                // after the circular interpolation finishes cutting, before any
                // shift-off-center or retract move. Unlike drilling's dwell (always the
                // penultimate waypoint, since a drill cycle never inserts anything after
                // its last cutting move), boring's shift-off-center move (when
                // `shiftRetract` is on) sits between the last cutting move and the final
                // retract, so "penultimate" isn't reliable here -- find the actual last
                // arc waypoint instead.
                let lastArcIndex = pass.waypoints.lastIndex { waypoint in
                    switch waypoint.motion {
                        case .arcCW, .arcCCW: return true
                        default: return false
                    }
                }

                for (index, wp) in pass.waypoints.enumerated() {

                    if let line = formatWaypoint(wp, from: previousPosition, modal: &modal) {
                        lines.append(line)
                    }
                    previousPosition = wp.position

                    // Dwell is emitted after the final cutting move and before
                    // the final retract. MachineSettings expresses dwell in
                    // seconds, and G04 P uses the same value here.
                    //
                    // A normal drilling pass has:
                    //   ... plunge -> final retract
                    //
                    // A peck drilling pass has:
                    //   ... final plunge -> final retract
                    //
                    // Therefore the penultimate waypoint is the final cutting
                    // move in both cases.
//                    if isDrilling,
//                       index == pass.waypoints.count - 2,
//                       let dwell = toolpath.settings.dwell,
//                       dwell > 0 {
//
//                        lines.append(
//                            "G04 P\(String(format: "%.3f", dwell)) (Drilling dwell)"
//                        )
//                    }

                    if let boringDwellTime, boringDwellTime > 0, index == lastArcIndex {
                        lines.append(
                            "G04 P\(String(format: "%.3f", boringDwellTime)) (Boring dwell)"
                        )
                    }
                }
            }
        }

        // End of section: clear of the work, air off, spindle off (it has to be off before the
        // next section's tool change). The program end is not written here.
        if modal.z != safeZText {
            lines.append("G00 Z\(safeZText)")
        }
        if options.airAssist {
            lines.append("M9 (Air Assist Off)")
        }
        lines.append("M05 (Spindle Stop)")

        return lines.joined(separator: "\n")
    }

    /// The lines that end a whole program: park at the machine's clearance position, then end.
    /// For the code that stitches the sections together to write ONCE, after the last section.
    public static func programFooter(parkAtClearance: Bool = true) -> [String] {
        var lines: [String] = []
        if parkAtClearance {
            lines.append("G28 (Go to Clearance Position)")
        }
        lines.append("M30 (Program End)")
        return lines
    }

    /// A toolpath runs at the machine-wide speed, except drilling, which carries its own.
    private static func spindleSpeed(for toolpath: SC.OutputToolpath, machineWide settings: SC.MachineSettings) -> Double {
        if case .drilling = toolpath.operation,
           abs(toolpath.settings.cutting.spindleSpeed - settings.cutting.spindleSpeed) > 0.000_001 {
            return toolpath.settings.cutting.spindleSpeed
        }
        return settings.cutting.spindleSpeed
    }

    /// Waits for the spindle to reach speed before the first cut.
    private func appendWarmUp(to lines: inout [String]) {
        guard options.spindleWarmUpSeconds > 0 else {
            return
        }
        lines.append("G04 P\(String(format: "%.3f", options.spindleWarmUpSeconds)) (Spindle warm-up)")
    }

    /// "-0.000" is valid but noisy; normalize it to "0.000".
    private func format(_ value: Double, decimals: Int = 3) -> String {
        let text = String(format: "%.\(decimals)f", value)
        return text.hasPrefix("-") && Double(text) == 0 ? String(text.dropFirst()) : text
    }

    /// The words the machine already has from the lines written before: X, Y, Z and the feed
    /// are only written when their value changes (the G word is written on every line, so a
    /// line can be read, or a job resumed from it, without looking at the ones before it).
    private struct ModalState {
        var x: String?
        var y: String?
        var z: String?
        var f: String?
    }

    /// `start` is the position the move begins from (the previous waypoint). Arc centers are
    /// absolute, and G02/G03 I/J are offsets from the arc START to the center.
    ///
    /// Returns nil when the move would write nothing new (the tool is already there).
    private func formatWaypoint(_ wp: SC.Waypoint, from start: SIMD3<Double>?, modal: inout ModalState) -> String? {

        let x = String(format: "%.3f", wp.position.x)
        let y = String(format: "%.3f", wp.position.y)
        let z = String(format: "%.3f", wp.position.z)
        let f = String(format: "%.1f", wp.feedRate)

        // An arc shorter than the output resolution would be written with the same X/Y as
        // its start, which a controller reads as a full circle. Write it as a line instead.
        // (A genuinely coincident start/end, closer than 1e-6, is left alone.)
        var motion = wp.motion
        if let start, motion.isArc {
            let distance = hypot(wp.position.x - start.x, wp.position.y - start.y)
            if distance >= 1e-6, format(start.x) == x, format(start.y) == y {
                motion = .linear
            }
        }

        switch motion {

            case .rapid:
                let axes = changedAxes(x: x, y: y, z: z, modal: &modal)
                guard !axes.isEmpty else {
                    return nil
                }
                modal.f = nil       // the feed is written again on the next cutting move
                return (["G00"] + axes).joined(separator: " ")

            case .linear:
                let axes = changedAxes(x: x, y: y, z: z, modal: &modal)
                guard !axes.isEmpty else {
                    return nil
                }
                return (["G01"] + axes + changedFeed(f, modal: &modal)).joined(separator: " ")

            case .arcCW(let center):
                return arc("G02", to: (x, y, z), feed: f, center: center, start: start, wp: wp, modal: &modal)

            case .arcCCW(let center):
                return arc("G03", to: (x, y, z), feed: f, center: center, start: start, wp: wp, modal: &modal)
        }
    }

    /// X, Y and Z words whose value differs from what the machine has. Updates `modal`.
    private func changedAxes(x: String, y: String, z: String, modal: inout ModalState) -> [String] {
        var words: [String] = []
        if modal.x != x { words.append("X\(x)"); modal.x = x }
        if modal.y != y { words.append("Y\(y)"); modal.y = y }
        if modal.z != z { words.append("Z\(z)"); modal.z = z }
        return words
    }

    /// The F word, if the feed differs from what the machine has. Updates `modal`.
    private func changedFeed(_ f: String, modal: inout ModalState) -> [String] {
        guard modal.f != f else {
            return []
        }
        modal.f = f
        return ["F\(f)"]
    }

    /// An arc always writes X, Y, I and J (a full circle has the same X/Y as its start, so
    /// leaving them out would be ambiguous); Z and the feed only when they change.
    private func arc(_ code: String,
                     to end: (x: String, y: String, z: String),
                     feed: String,
                     center: CGPoint,
                     start: SIMD3<Double>?,
                     wp: SC.Waypoint,
                     modal: inout ModalState) -> String {

        let origin = start ?? wp.position
        let i = format(Double(center.x) - Double(origin.x))
        let j = format(Double(center.y) - Double(origin.y))

        var words = [code, "X\(end.x)", "Y\(end.y)"]
        modal.x = end.x
        modal.y = end.y
        if modal.z != end.z {
            words.append("Z\(end.z)")
            modal.z = end.z
        }
        words += ["I\(i)", "J\(j)"]
        words += changedFeed(feed, modal: &modal)
        return words.joined(separator: " ")
    }
}
