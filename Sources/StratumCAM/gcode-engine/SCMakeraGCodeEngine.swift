//
//  SCGCodeEngine.swift
//  StratumCAM
//
//  Native Carvera G-code generator. The command sequences follow Makera's Carvera.cps post
//  (header, `T<n>M6` tool changes, `S<rpm> M3`, G54, `M5`/`G28`/`M30` footer, arc I/J relative to the arc START).
//  Use SCPostEngine (which runs the real .cps) as an oracle: both engines should agree
//  on every non-comment line.
//

import Foundation

public struct SCMakeraGCodeEngine {

    // MARK: - Public types

    public struct Options {

        /// Mirrors the post's "Manual Tool Change Behavior" property.
        public enum ToolChangeMode {
            /// `T<n>M6` for any tool number (stock Carvera Air / Z1). Post: "carvAirMtc".
            case automatic
            /// Stock C1: tool numbers above 6 are an error; tools flagged `manualToolChange` get the manual sequence. Post: "error6".
            case stockC1
            /// Stock C1 with manual tool changes for tool > 6 or flagged tools (pause + collet release/close + probe). Post: "fusionMtc".
            case manual
            /// Community firmware: `T<n>M6 C1|C0|H<offset>` from the TLO comment, optional collet parameter. Post: "carvcomMtc".
            case community
        }

        public var toolChangeMode: ToolChangeMode = .automatic
        /// `M400 / M851 S100` before the spindle starts and `M400 / M852` after it stops (post default: on).
        public var useExternalControl = true
        /// `G28` before `M30`.
        public var returnToClearance = true
        public var writeToolList = true
        public var programName = "StratumCAM"
        /// Community firmware: append the tool comment to `M6` (e.g. `T1M6 X-12 R3`).
        public var toolCommentAsChangeParameters = false
        /// Community firmware: append the collet parameter (S1...S6) when the shank diameter changes.
        public var colletChangeOnShankSizeChange = false

        public init() {}
    }

    public enum GenerationError: Error, LocalizedError {
        case noToolpaths
        case toolNumberNotSupported(Int)

        public var errorDescription: String? {
            switch self {
                case .noToolpaths:
                    return "There are no toolpaths to convert to G-code."
                case .toolNumberNotSupported(let number):
                    return "Tool T\(number) is not supported by a stock Carvera C1 (T1-T6). " +
                           "Choose another tool change mode or renumber the tool."
            }
        }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - Generation

    /// Converts generated toolpaths into Carvera G-code.
    ///
    /// - Parameter settings: kept for API compatibility. The Carvera clearance position is the machine's
    ///   own `G28`, so `settings.safeZ` is not used for the header/footer anymore.
    public func generateGCode(from toolpaths: [SC.OutputToolpath],
                              settings: SC.MachineSettings) throws -> String {

        guard !toolpaths.isEmpty else { throw GenerationError.noToolpaths }

        let tools = toolpaths.map(\.tool)

        var writer = Writer(options: options)
        writer.writeHeader(toolpaths: toolpaths, tools: tools)

        for (index, toolpath) in toolpaths.enumerated() {
            try writer.writeSection(toolpath,
                                    name: Self.sectionName(for: toolpath, index: index),
                                    tool: tools[index],
                                    previousTool: index > 0 ? tools[index - 1] : nil)
        }

        writer.writeFooter()
        return writer.lines.joined(separator: "\n")
    }

    private static func sectionName(for toolpath: SC.OutputToolpath, index: Int) -> String {
        if case .drilling = toolpath.operation { return "Drilling \(index + 1)" }
        if case .boring = toolpath.operation { return "Boring \(index + 1)" }
        return "Toolpath \(index + 1)"
    }

    // MARK: - Writer

    private struct Point {
        var x: Double
        var y: Double
        var z: Double
    }

    private struct Writer {

        let options: Options
        var lines: [String] = []

        // Modal state: mirrors the post's modal output variables, so unchanged words are omitted.
        private var motionG: Int?
        private var lastX: String?
        private var lastY: String?
        private var lastZ: String?
        private var lastI: String?
        private var lastJ: String?
        private var lastF: String?
        private var position: Point?

        private var lastRPM: Int?
        private var lastClockwise: Bool?
        private var forceSpindle = false
        private var currentWorkOffset: Int?
        private var previousToolChangeWasManual = false

        init(options: Options) {
            self.options = options
        }

        // MARK: Formatting

        /// 3 decimals, trailing zeros trimmed, decimal point kept ("10.", "1.5", "-0.25"), like the post.
        private static func number(_ value: Double) -> String {
            let scaled = (abs(value) * 1000).rounded(.toNearestOrAwayFromZero)
            if scaled == 0 { return "0." }
            var text = String(format: "%.3f", scaled / 1000)
            while text.hasSuffix("0") { text.removeLast() }
            return (value < 0 ? "-" : "") + text
        }

        private static func plain(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(value)
        }

        /// Returns the word only if its text changed since last time.
        private static func modal(_ prefix: String, _ text: String, _ last: inout String?) -> String? {
            if last == text { return nil }
            last = text
            return prefix + text
        }

        private mutating func emit(_ words: [String?]) {
            let text = words.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            if !text.isEmpty { lines.append(text) }
        }

        private mutating func comment(_ text: String) {
            let cleaned = text.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            lines.append("(" + cleaned + ")")
        }

        private mutating func motion(_ number: Int) -> String? {
            if motionG == number { return nil }
            motionG = number
            return "G\(number)"
        }

        private mutating func forceXYZ() {
            lastX = nil
            lastY = nil
            lastZ = nil
        }

        // MARK: Header / footer

        mutating func writeHeader(toolpaths: [SC.OutputToolpath], tools: [SC.ToolParams]) {

            comment(options.programName)

            if options.writeToolList {
                var seen = Set<Int>()
                for tool in tools where seen.insert(tool.number).inserted {

                    var zValues: [Double] = []
                    for (index, other) in tools.enumerated() where other.number == tool.number {
                        for pass in toolpaths[index].passes {
                            for waypoint in pass.waypoints {
                                zValues.append(Double(waypoint.position.z))
                            }
                        }
                    }

                    var line = "T\(tool.number)  \(tool.name)  D=\(Writer.number(tool.diameter))"
                    if let zMin = zValues.min() {
                        line += " - ZMIN=\(Writer.number(zMin))"
                    }
                    comment(line)
                }
            }

            emit(["G90", "G94"])
            emit(["G17"])
            emit(["G21"])
        }

        mutating func writeFooter() {
            stopSpindle()
            if options.returnToClearance {
                emit(["G28"])
            }
            emit(["M30"])
        }

        // MARK: Spindle

        private mutating func stopSpindle() {
            emit(["M5"])
            if options.useExternalControl {
                emit(["M400"])
                emit(["M852"])
            }
            forceSpindle = true
        }

        private mutating func startSpindle(rpm: Int, clockwise: Bool) {
            if options.useExternalControl {
                emit(["M400"])
                emit(["M851 S100"])
            }
            // The speed is always written, even when unchanged: after M6 the machine may not keep it.
            emit(["S\(rpm)", clockwise ? "M3" : "M4"])
            lastRPM = rpm
            lastClockwise = clockwise
            forceSpindle = false
        }

        // MARK: Sections

        mutating func writeSection(_ toolpath: SC.OutputToolpath,
                                   name: String,
                                   tool: SC.ToolParams,
                                   previousTool: SC.ToolParams?) throws {

            let isFirst = previousTool == nil
            let insertToolCall = isFirst || previousTool?.number != tool.number
            let rpm = Int(Double(toolpath.settings.cutting.spindleSpeed).rounded())
            let spindleChanged = insertToolCall || forceSpindle || lastRPM != rpm || lastClockwise != tool.clockwise

            // Boring's dwell happens after the last arc of each pass.
            let boringDwellTime: Double? = {
                if case .boring(_, let dwellTime, _) = toolpath.operation {
                    return dwellTime
                }
                return nil
            }()

            if insertToolCall && !isFirst {
                stopSpindle()
            }

            lines.append("")
            comment(name)

            if insertToolCall {
                try toolChange(tool, previous: previousTool)
                currentWorkOffset = nil          // work offset is re-issued after every tool change
            }

            if spindleChanged {
                startSpindle(rpm: rpm, clockwise: tool.clockwise)
            }

            if currentWorkOffset != 1 {
                emit(["G54"])
                currentWorkOffset = 1
            }

            // Approach: XY first, then Z (the Z-first rule only applies if we'd move up into the section).
            if let initial = toolpath.passes.compactMap({ $0.waypoints.first }).first.map(Writer.point) {

                forceXYZ()

                if let current = position, current.z < initial.z - 1e-6 {
                    let z = Writer.modal("Z", Writer.number(initial.z), &lastZ)
                    let g = motion(0)
                    emit([g, z])
                }

                if insertToolCall {
                    motionG = nil                      // the post re-issues G0 after a tool change
                }

                let g = motion(0)
                let x = Writer.modal("X", Writer.number(initial.x), &lastX)
                let y = Writer.modal("Y", Writer.number(initial.y), &lastY)
                emit([g, x, y])

                if insertToolCall {
                    let z = Writer.modal("Z", Writer.number(initial.z), &lastZ)
                    emit([z])
                }
                position = initial
            }

            // Moves
            for pass in toolpath.passes {

                comment("--- Pass Depth: \(pass.depthZ) ---")

                let lastArcIndex = pass.waypoints.lastIndex { waypoint in
                    switch waypoint.motion {
                        case .arcCW, .arcCCW: return true
                        default: return false
                    }
                }

                for (index, waypoint) in pass.waypoints.enumerated() {

                    let target = Writer.point(waypoint)
                    let feed = Double(waypoint.feedRate)
                    let nextIsMotion = index + 1 < pass.waypoints.count

                    switch waypoint.motion {

                        case .rapid:
                            rapid(to: target)

                        case .linear:
                            linear(to: target, feed: feed, nextIsMotion: nextIsMotion)

                        case .arcCW(let center):
                            arc(to: target, cx: Double(center.x), cy: Double(center.y),
                                clockwise: true, feed: feed, nextIsMotion: nextIsMotion)

                        case .arcCCW(let center):
                            arc(to: target, cx: Double(center.x), cy: Double(center.y),
                                clockwise: false, feed: feed, nextIsMotion: nextIsMotion)
                    }

                    if let boringDwellTime, boringDwellTime > 0, index == lastArcIndex {
                        dwell(boringDwellTime)
                    }
                }
            }

            // End of section: force everything on the next one.
            forceXYZ()
            lastF = nil
        }

        private static func point(_ waypoint: SC.Waypoint) -> Point {
            Point(x: Double(waypoint.position.x),
                  y: Double(waypoint.position.y),
                  z: Double(waypoint.position.z))
        }

        // MARK: Motion

        private mutating func rapid(to p: Point) {
            let x = Writer.modal("X", Writer.number(p.x), &lastX)
            let y = Writer.modal("Y", Writer.number(p.y), &lastY)
            let z = Writer.modal("Z", Writer.number(p.z), &lastZ)
            if x != nil || y != nil || z != nil {
                let g = motion(0)
                emit([g, x, y, z])
                lastF = nil                      // feed is re-issued on the next cutting move
            }
            position = p
        }

        private mutating func linear(to p: Point, feed: Double, nextIsMotion: Bool) {
            let x = Writer.modal("X", Writer.number(p.x), &lastX)
            let y = Writer.modal("Y", Writer.number(p.y), &lastY)
            let z = Writer.modal("Z", Writer.number(p.z), &lastZ)
            let f = Writer.modal("F", String(Int(feed.rounded())), &lastF)

            if x != nil || y != nil || z != nil {
                let g = motion(1)
                emit([g, x, y, z, f])
            } else if f != nil {
                if nextIsMotion {
                    lastF = nil                  // fold the feed into the next move instead
                } else {
                    let g = motion(1)
                    emit([g, f])
                }
            }
            position = p
        }

        /// Arc in the XY plane. The centre is absolute; I/J are written relative to the arc's START point.
        private mutating func arc(to end: Point, cx: Double, cy: Double, clockwise: Bool, feed: Double, nextIsMotion: Bool) {

            let start = position ?? end
            let radius = hypot(start.x - cx, start.y - cy)
            let isFullCircle = hypot(end.x - start.x, end.y - start.y) < 1e-6
            let isHelical = abs(end.z - start.z) > 1e-6

            // Too small for an arc, or a helical full circle: the post emits line segments instead.
            if radius < 0.01 {
                linear(to: end, feed: feed, nextIsMotion: nextIsMotion)
                return
            }
            if isFullCircle && isHelical {
                linearizeArc(from: start, to: end, cx: cx, cy: cy, clockwise: clockwise, feed: feed, isFull: true)
                return
            }

            // A real arc, but shorter than the output resolution: start and end would be
            // written with the same X/Y, which a controller reads as a full circle. Write the
            // (sub-0.001 mm) move as a line instead.
            if !isFullCircle,
               Writer.number(end.x) == Writer.number(start.x),
               Writer.number(end.y) == Writer.number(start.y) {
                linear(to: end, feed: feed, nextIsMotion: nextIsMotion)
                return
            }

            // The post forces X, Y, I and J on every arc.
            lastX = nil
            lastY = nil
            lastI = nil
            lastJ = nil

            let g = motion(clockwise ? 2 : 3)
            let x = Writer.modal("X", Writer.number(end.x), &lastX)
            let i = Writer.modal("I", Writer.number(cx - start.x), &lastI)
            let j = Writer.modal("J", Writer.number(cy - start.y), &lastJ)
            let f = Writer.modal("F", String(Int(feed.rounded())), &lastF)

            if isFullCircle {
                emit([g, x, i, j, f])
            } else {
                let y = Writer.modal("Y", Writer.number(end.y), &lastY)
                let z = Writer.modal("Z", Writer.number(end.z), &lastZ)
                emit([g, x, y, z, i, j, f])
            }
            position = end
        }

        private mutating func linearizeArc(from start: Point, to end: Point, cx: Double, cy: Double,
                                           clockwise: Bool, feed: Double, isFull: Bool) {

            let tolerance = 0.002
            let radius = hypot(start.x - cx, start.y - cy)
            let a0 = atan2(start.y - cy, start.x - cx)
            let a1 = atan2(end.y - cy, end.x - cx)

            var sweep = isFull ? 2 * Double.pi : (clockwise ? a0 - a1 : a1 - a0)
            while !isFull && sweep <= 0 { sweep += 2 * Double.pi }

            let step = radius > tolerance ? 2 * acos(1 - tolerance / radius) : Double.pi / 4
            let segments = max(2, Int((sweep / max(step, 1e-3)).rounded(.up)))

            for index in 1...segments {
                let t = Double(index) / Double(segments)
                let angle = clockwise ? a0 - sweep * t : a0 + sweep * t
                let point = index == segments
                    ? end
                    : Point(x: cx + radius * cos(angle),
                            y: cy + radius * sin(angle),
                            z: start.z + (end.z - start.z) * t)
                linear(to: point, feed: feed, nextIsMotion: true)
            }
        }

        private mutating func dwell(_ seconds: Double) {
            let clamped = min(max(seconds, 0.001), 99999.999)
            emit(["G4", "P" + Writer.number(clamped)])
        }

        // MARK: Tool changes

        private mutating func toolChange(_ tool: SC.ToolParams, previous: SC.ToolParams?) throws {

            let n = tool.number
            let isFirst = previous == nil

            switch options.toolChangeMode {

                case .automatic:
                    plainToolChange(tool, removeManualTool: false)

                case .stockC1:
                    if n > 6 { throw GenerationError.toolNumberNotSupported(n) }
                    if tool.manualToolChange {
                        manualToolChange(tool, isFirst: isFirst)
                    } else {
                        plainToolChange(tool, removeManualTool: false)
                    }

                case .manual:
                    if n > 6 || tool.manualToolChange {
                        manualToolChange(tool, isFirst: isFirst)
                    } else {
                        plainToolChange(tool, removeManualTool: true)
                    }

                case .community:
                    communityToolChange(tool, previous: previous)
            }
        }

        private mutating func plainToolChange(_ tool: SC.ToolParams, removeManualTool: Bool) {

            if removeManualTool && previousToolChangeWasManual {
                comment("Manual Tool Removal as a result of previous manual tool change")
                comment("setup for tool change")
                emit(["G28"])
                comment("Paused. Prepare to remove tool from collet. Pressing play will release collet")
                emit(["M27"])
                emit(["M600"])
                emit(["M490.2"])
                comment("Paused. Pressing play will resume program. The program expects an empty collet after this point.")
                emit(["M27"])
                emit(["M600"])
                emit(["M493.2 T-1"])
            }

            emit(["T\(tool.number)M6"])
            if !tool.comment.isEmpty { comment(tool.comment) }
            previousToolChangeWasManual = false
        }

        private mutating func manualToolChange(_ tool: SC.ToolParams, isFirst: Bool) {

            let tlo = Writer.parseTLO(tool.comment)

            comment("Manual Tool Change To #\(tool.number)")
            if !tool.comment.isEmpty { comment(tool.comment) }
            comment("Setup for tool change")

            if previousToolChangeWasManual || isFirst {
                emit(["G28"])
                comment("Paused. Prepare to remove tool from collet. Pressing play will release collet")
                emit(["M27"])
                emit(["M600"])
                emit(["M490.2 (Open Collet)"])
            } else {
                emit(["T-1 M6"])
                emit(["G28"])
            }

            previousToolChangeWasManual = true

            comment("Paused. Prepare to add new tool to collet. Pressing play will close collet")
            emit(["M27"])
            emit(["M600"])
            emit(["M490.1 (Close Collet)"])

            if tlo == "M" || Double(tlo ?? "") != nil {
                comment("Paused. Use the manual control interface to set the tool length.")
                comment("Pressing play will goto the clearance position, then continue the program.")
                emit(["M27"])
                emit(["M600"])
                emit(["G28 (Move To Clearance)"])
            } else {
                comment("Paused. Pressing play will calibrate the tool length and continue the program")
                emit(["M27"])
                emit(["M600"])
                emit(["M493.2T1 (Set tool number to 1 so TLO can be set)"])
                emit(["M491 (Calibrate Tool Length)"])
            }
        }

        private mutating func communityToolChange(_ tool: SC.ToolParams, previous: SC.ToolParams?) {

            let n = tool.number

            if let tlo = Writer.parseTLO(tool.comment), !options.toolCommentAsChangeParameters {
                switch tlo {
                    case "A":
                        emit(["T\(n)M6 C1"])
                    case "M":
                        emit(["T\(n)M6 C0"])
                    default:
                        // Note: the .cps writes this tool change twice (`T1M6 H-14` and `M6 T1 H-14`); once is enough.
                        if let offset = Double(tlo) {
                            emit(["T\(n)M6 H\(Writer.plain(offset))"])
                        } else {
                            emit(["T\(n)M6"])
                        }
                }
            } else {
                var parameters = options.toolCommentAsChangeParameters ? tool.comment : ""

                if options.colletChangeOnShankSizeChange {
                    let shaft = tool.shaftDiameter ?? 0
                    let previousShaft = previous?.shaftDiameter ?? 0
                    if previous == nil || abs(shaft - previousShaft) > 0.001 {
                        parameters += " " + Writer.shankSuffix(shaft)
                    }
                }
                emit([("T\(n)M6 " + parameters).trimmingCharacters(in: .whitespaces)])
            }
            previousToolChangeWasManual = false
        }

        /// Extracts the value of `TLO:<A|M|number>` from a tool comment.
        private static func parseTLO(_ comment: String) -> String? {
            guard let range = comment.range(of: "TLO:") else { return nil }
            let allowed = Set("AMam0123456789.-")
            let value = comment[range.upperBound...].prefix { allowed.contains($0) }
            return value.isEmpty ? nil : String(value).uppercased()
        }

        /// Collet parameter for a shank diameter in mm (numbering as in Carvera.cps).
        private static func shankSuffix(_ diameter: Double) -> String {
            let table: [(diameter: Double, suffix: String)] = [
                (3, "S1"), (3.175, "S2"), (4, "S3"), (6.35, "S5"), (6, "S4"), (8, "S6")
            ]
            return table.first { abs(diameter - $0.diameter) <= 0.01 }?.suffix ?? ""
        }
    }
}
