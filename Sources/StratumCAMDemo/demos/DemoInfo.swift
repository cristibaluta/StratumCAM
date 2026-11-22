//
//  DemoInfo.swift
//  StratumCAM
//
//  Human-readable description of what a demo is doing: the operation and its parameters,
//  the tool, and the machine settings. Shown by `DemoInfoOverlay` on top of the canvas.
//

import Foundation
import StratumCAM

struct DemoInfo: Equatable {

    struct Row: Equatable {
        let label: String
        let value: String

        init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    struct Block: Equatable {
        var title: String
        var rows: [Row]
    }

    var blocks: [Block]

    var isEmpty: Bool {
        blocks.isEmpty
    }

    init(blocks: [Block] = []) {
        self.blocks = blocks
    }

    /// The standard three blocks: Operation, Tool, Machine.
    ///
    /// - Parameter contours: The contours the operation runs on, only used to report how many
    ///   shapes (and islands) there are. Leave empty when that isn't meaningful.
    init(operation: SC.MachiningOperation,
         tool: SC.ToolParams,
         settings: SC.MachineSettings,
         contours: [SC.Contour] = []) {

        self.blocks = [
            DemoInfo.operationBlock(operation, tool: tool, contours: contours),
            DemoInfo.toolBlock(tool),
            DemoInfo.machineBlock(settings, tool: tool)
        ]
    }

    /// Appends ` · suffix` to every block title, to tell apart the stages of a demo that
    /// combines several runs (e.g. two facing passes with different tools).
    func labeled(_ suffix: String) -> DemoInfo {
        DemoInfo(blocks: blocks.map { Block(title: "\($0.title) · \(suffix)", rows: $0.rows) })
    }

    static func + (lhs: DemoInfo, rhs: DemoInfo) -> DemoInfo {
        DemoInfo(blocks: lhs.blocks + rhs.blocks)
    }
}

// MARK: - Operation

extension DemoInfo {

    static func operationBlock(_ operation: SC.MachiningOperation,
                               tool: SC.ToolParams,
                               contours: [SC.Contour] = []) -> Block {
        var rows: [Row] = []

        switch operation {
            case .facing(let direction, let extensionLength):
                rows.append(Row("Operation", "Facing"))
                rows.append(Row("Direction", direction.rawValue))
                rows.append(Row("Extension", num(extensionLength, "mm")))

            case .slotting(let depthPerPass, let pattern, let entry):
                rows.append(Row("Operation", "Slotting"))
                rows.append(Row("Pattern", describe(pattern)))
                rows.append(Row("Entry", describe(entry)))
                rows.append(Row("Depth per pass", num(depthPerPass, "mm")))

            case .threadMilling(let pitch, let isInternal, let direction, let radialPasses, let targetDiameter):
                rows.append(Row("Operation", "Thread milling"))
                rows.append(Row("Thread", isInternal ? "Internal" : "External"))
                rows.append(Row("Handedness", direction == .rightHand ? "Right-hand" : "Left-hand"))
                rows.append(Row("Pitch", num(pitch, "mm")))
                rows.append(Row("Target Ø", num(targetDiameter, "mm")))
                rows.append(Row("Radial passes", "\(radialPasses)"))

            case .engrave(let entry):
                rows.append(Row("Operation", "Engrave"))
                rows.append(Row("Entry", describe(entry)))

            case .contour(let side, let direction, let entry, let leadIn, let leadOut, let tabs):
                rows.append(Row("Operation", "Contour"))
                rows.append(Row("Side", side.rawValue))
                rows.append(Row("Direction", direction.rawValue))
                rows.append(Row("Entry", describe(entry)))
                rows.append(Row("Lead-in", describe(leadIn)))
                rows.append(Row("Lead-out", describe(leadOut)))
                rows.append(Row("Tabs", describe(tabs)))

            case .pocket(let direction, let pattern, let entry):
                rows.append(Row("Operation", "Pocket"))
                rows.append(Row("Pattern", describe(pattern)))
                rows.append(Row("Direction", direction.rawValue))
                rows.append(Row("Entry", describe(entry)))

            case .pocket3D(let direction, let pattern, let entry):
                rows.append(Row("Operation", "Pocket 3D"))
                rows.append(Row("Pattern", describe(pattern)))
                rows.append(Row("Direction", direction.rawValue))
                rows.append(Row("Entry", describe(entry)))

            case .drilling(let peckDepth):
                rows.append(Row("Operation", "Drilling"))
                rows.append(Row("Peck depth", peckDepth.map { num($0, "mm") } ?? "None (continuous)"))

            case .chamfer(let params):
                rows.append(Row("Operation", "Chamfer"))
                rows.append(Row("Edge", params.edge.rawValue))
                if let edgeZ = params.edgeZ {
                    rows.append(Row("Edge Z", num(edgeZ, "mm")))
                }
                rows.append(Row("Side", params.side.rawValue))
                rows.append(Row("Direction", params.direction.rawValue))
                rows.append(Row("Width", num(params.width, "mm")))
                rows.append(Row("Depth", params.depth.map { num($0, "mm") } ?? "Auto (from V angle)"))
                rows.append(Row("Tip offset", num(params.tipOffset, "mm")))
                if let bevel = params.resolvedBevel(for: tool) {
                    rows.append(Row("Bevel", "\(num(bevel.width)) × \(num(bevel.depth)) mm"))
                }

            case .boring(let targetDiameter, let dwellTime, let shiftRetract):
                rows.append(Row("Operation", "Boring"))
                rows.append(Row("Target Ø", num(targetDiameter, "mm")))
                rows.append(Row("Dwell", dwellTime.map { num($0, "s") } ?? "None"))
                rows.append(Row("Shift retract", shiftRetract ? "Yes" : "No"))

            case .counterbore(let diameter, let depth, let direction, let entry):
                rows.append(Row("Operation", "Counterbore"))
                rows.append(Row("Ø", num(diameter, "mm")))
                rows.append(Row("Depth", num(depth, "mm")))
                rows.append(Row("Direction", direction.rawValue))
                rows.append(Row("Entry", describe(entry)))
        }

        if !contours.isEmpty {
            let islands = contours.reduce(0) { $0 + $1.islands.count }
            rows.append(Row("Shapes", islands > 0 ? "\(contours.count) (+ \(islands) islands)" : "\(contours.count)"))
        }

        return Block(title: "Operation", rows: rows)
    }

    // MARK: Describers

    static func describe(_ entry: SC.EntryStrategy) -> String {
        switch entry {
            case .plunge:
                return "Plunge"
            case .ramp(let angle):
                return "Ramp \(num(angle))°"
            case .helix(let angle):
                return "Helix \(num(angle))°"
            case .fromOpenEnd(let stepover):
                return "From open end, stepover \(num(stepover * 100))%"
        }
    }

    static func describe(_ pattern: SC.PocketClearingPattern) -> String {
        switch pattern {
            case .offset:
                return "Offset"
            case .concentric(let direction):
                return "Concentric, \(describe(direction))"
            case .raster:
                return "Raster"
            case .spiral(let direction):
                return "Spiral, \(describe(direction))"
            case .trochoidal(let settings):
                return "Trochoidal, \(describe(settings))"
            case .adaptive(let settings):
                return "Adaptive, \(describe(settings))"
        }
    }

    static func describe(_ pattern: SC.SlotClearingPattern) -> String {
        switch pattern {
            case .raster:
                return "Raster"
            case .trochoidal(let settings):
                return "Trochoidal, \(describe(settings))"
            case .adaptive(let settings):
                return "Adaptive, \(describe(settings))"
        }
    }

    private static func describe(_ direction: SC.SpiralDirection) -> String {
        switch direction {
            case .insideOut: return "inside-out"
            case .outsideIn: return "outside-in"
        }
    }

    private static func describe(_ settings: SC.TrochoidalSettings) -> String {
        "engagement \(num(settings.radialEngagement)), loop r \(num(settings.loopRadius))"
    }

    private static func describe(_ settings: SC.AdaptiveSettings) -> String {
        "optimal load \(num(settings.optimalLoad, "mm"))"
    }

    private static func describe(_ leadInOut: SC.LeadInOut?) -> String {
        guard let leadInOut else {
            return "None"
        }
        let style: String
        switch leadInOut.style {
            case .linear(let length):
                style = "Linear \(num(length)) mm"
            case .arc(let radius, let sweepAngleDegrees):
                style = "Arc r\(num(radius)) mm, \(num(sweepAngleDegrees))°"
        }
        return "\(style) @ F\(num(leadInOut.feedRate))"
    }

    private static func describe(_ tabs: [SC.HoldingTab]) -> String {
        guard !tabs.isEmpty else {
            return "None"
        }
        let sizes = Set(tabs.map { "\(num($0.width)) × \(num($0.height)) mm" }).sorted()
        return "\(tabs.count) · \(sizes.joined(separator: ", "))"
    }
}

// MARK: - Tool

extension DemoInfo {

    static func toolBlock(_ tool: SC.ToolParams) -> Block {
        var rows: [Row] = []
        rows.append(Row("Name", tool.name))
        rows.append(Row("Type", describe(tool.type)))
        rows.append(Row("Ø", num(tool.diameter, "mm")))
        rows.append(Row("Flute length", num(tool.fluteLength, "mm")))
        if tool.type == .vBit {
            if let vAngle = tool.vAngle {
                rows.append(Row("V angle", "\(num(vAngle))°"))
            }
            rows.append(Row("Tip width", num(tool.tipWidth, "mm")))
            if let flank = tool.flankHeight {
                rows.append(Row("Flank height", num(flank, "mm")))
            }
        }
        if let shaft = tool.shaftDiameter {
            rows.append(Row("Shank Ø", num(shaft, "mm")))
        }
        rows.append(Row("Tool #", "T\(tool.number)"))
        rows.append(Row("Spindle", tool.clockwise ? "CW (M3)" : "CCW (M4)"))
        if tool.manualToolChange {
            rows.append(Row("Tool change", "Manual"))
        }
        if !tool.comment.isEmpty {
            rows.append(Row("Comment", tool.comment))
        }
        return Block(title: "Tool", rows: rows)
    }

    private static func describe(_ type: SC.ToolType) -> String {
        switch type {
            case .flatEndMill: return "Flat end mill"
            case .ballEndMill: return "Ball end mill"
            case .vBit:        return "V-bit"
            case .drill:       return "Drill"
            case .threadMill:  return "Thread mill"
        }
    }
}

// MARK: - Machine settings

extension DemoInfo {

    static func machineBlock(_ settings: SC.MachineSettings, tool: SC.ToolParams) -> Block {
        let cutting = settings.cutting
        var rows: [Row] = []
        rows.append(Row("Spindle speed", "\(num(cutting.spindleSpeed)) rpm"))
        rows.append(Row("Feed rate", "\(num(cutting.feedRate)) mm/min"))
        rows.append(Row("Plunge rate", "\(num(cutting.plungeRate)) mm/min"))
        rows.append(Row("Stepdown", num(cutting.stepdown, "mm")))
        rows.append(Row("Stepover", "\(num(cutting.stepoverPercentage * 100))% (\(num(cutting.stepoverPercentage * tool.diameter)) mm)"))
        if cutting.maxOptimalLoad > 0 {
            rows.append(Row("Max optimal load", num(cutting.maxOptimalLoad, "mm")))
        }
        rows.append(Row("Safe Z", num(settings.safeZ, "mm")))
        rows.append(Row("Retract Z", num(settings.retractZ, "mm")))
        if let entryZ = settings.entryZ {
            rows.append(Row("Entry Z", num(entryZ, "mm")))
        }
        rows.append(Row("Target depth", num(settings.targetDepth, "mm")))
        rows.append(Row("Retract policy", describe(settings.retractPolicy)))
        rows.append(Row("Allowance", num(settings.allowance, "mm")))
        rows.append(Row("Finishing pass", settings.finishingPass ? "Yes" : "No"))
        return Block(title: "Machine", rows: rows)
    }

    private static func describe(_ policy: SC.RetractPolicy) -> String {
        switch policy {
            case .safeZ:     return "Safe Z"
            case .clearance: return "Clearance"
            case .none:      return "None"
        }
    }
}

// MARK: - Number formatting

extension DemoInfo {

    /// A number without trailing zeros (`3.175`, `12000`, `0.5`), optionally followed by a unit.
    static func num(_ value: Double, _ unit: String = "") -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        if text == "-0" || text.isEmpty {
            text = "0"
        }
        return unit.isEmpty ? text : "\(text) \(unit)"
    }
}
