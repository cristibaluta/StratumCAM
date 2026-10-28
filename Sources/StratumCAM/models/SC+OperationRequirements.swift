//
//  SC+OperationRequirements.swift
//  StratumCAM
//
//  What a `MachiningOperation` takes, allows and rules out -- the library's description of
//  itself. An app only has to build the inputs (operation, tool, settings, contours) and draw
//  controls for whatever `requirements` lists; it never needs its own table of "which
//  operation has a direction / a pattern / a ramp" or "which values go with which".
//
//   - `requirements`   which parameters the operation has, and which values each accepts
//   - `validate(tool:)` whether the values it carries (and their combinations) are usable;
//                      it fails with the library's own `SC.Error`, naming the parameter by its
//                      `ParameterField` id, e.g. `.invalidParameter("pattern.adaptive.optimalLoad")`
//   - `direction`, `entry`, ... read and write a parameter without switching over every case
//

import Foundation

extension SC {

    /// Which inputs and parameters an operation reads, and which values it accepts for them.
    ///
    /// The answer depends on the operation *value*, not only on its case: an adaptive pocket is
    /// driven by its optimal load and ignores the stepover, an offset pocket does not.
    public struct OperationRequirements: Sendable, Equatable {

        // MARK: General inputs (`MachineSettings` / `CuttingData`)

        /// The operation cuts down to a depth chosen by the caller (`MachineSettings.targetDepth`).
        /// False when the operation derives its own depth: a counterbore has `depth`, a
        /// chamfer takes it from its width and the V-bit angle.
        public var usesEndZ: Bool

        /// The operation steps down in several passes by `CuttingData.stepdown`. False for
        /// single-pass operations, and for those that step by their own value (a slot's
        /// `depthPerPass`, a thread's pitch).
        public var usesStepdown: Bool

        /// The operation reads the radial stepover (`CuttingData.stepoverPercentage`).
        public var usesStepover: Bool

        /// The operation can leave stock for a finishing pass (`MachineSettings.allowance` and
        /// `MachineSettings.finishingPass`). False for a contour cut on the line, which has no
        /// side to leave stock on, and for the operations that cut a single exact size.
        public var usesAllowance: Bool

        // MARK: Parameters of the operation itself

        /// The operation has a climb / conventional direction.
        public var usesDirection: Bool

        /// The operation has a cut side (inside / outside / on the line) of its own.
        public var usesSide: Bool

        /// The operation takes a lead-in and a lead-out.
        public var usesLeadInOut: Bool

        /// The operation takes holding tabs.
        public var usesHoldingTabs: Bool

        /// The entry strategies the operation accepts, in the order they should be offered,
        /// each with its default parameters (`EntryStrategy.defaults`). Empty when the
        /// operation has no entry strategy at all.
        public var entries: [EntryStrategy]

        /// The pocket clearing patterns on offer, in order, each with its default parameters
        /// (`PocketClearingPattern.defaults`). Empty unless the operation is a pocket.
        public var pocketPatterns: [PocketClearingPattern]

        /// The slot clearing patterns on offer, in order, each with its default parameters
        /// (`SlotClearingPattern.defaults`). Empty unless the operation is a slot.
        public var slotPatterns: [SlotClearingPattern]

        /// The operation has an entry strategy.
        public var usesEntry: Bool {
            !entries.isEmpty
        }

        /// The operation has a clearing pattern.
        public var usesClearingPattern: Bool {
            !pocketPatterns.isEmpty || !slotPatterns.isEmpty
        }

        /// Whether `entry` is one of the strategies the operation accepts. Only the kind of
        /// strategy counts, not its parameters (a 3° ramp is as good as the default 2° one).
        public func accepts(_ entry: EntryStrategy) -> Bool {
            entries.contains { offered in
                switch (offered, entry) {
                    case (.plunge, .plunge), (.ramp, .ramp), (.helix, .helix), (.fromOpenEnd, .fromOpenEnd):
                        return true
                    default:
                        return false
                }
            }
        }

        public init(usesEndZ: Bool = true,
                    usesStepdown: Bool = false,
                    usesStepover: Bool = false,
                    usesAllowance: Bool = false,
                    usesDirection: Bool = false,
                    usesSide: Bool = false,
                    usesLeadInOut: Bool = false,
                    usesHoldingTabs: Bool = false,
                    entries: [EntryStrategy] = [],
                    pocketPatterns: [PocketClearingPattern] = [],
                    slotPatterns: [SlotClearingPattern] = []) {
            self.usesEndZ = usesEndZ
            self.usesStepdown = usesStepdown
            self.usesStepover = usesStepover
            self.usesAllowance = usesAllowance
            self.usesDirection = usesDirection
            self.usesSide = usesSide
            self.usesLeadInOut = usesLeadInOut
            self.usesHoldingTabs = usesHoldingTabs
            self.entries = entries
            self.pocketPatterns = pocketPatterns
            self.slotPatterns = slotPatterns
        }
    }
}

// MARK: - What each model offers by default

extension SC.EntryStrategy {

    /// Every entry strategy, with the parameters a freshly picked one starts with.
    public static let defaults: [SC.EntryStrategy] = [
        .plunge,
        .ramp(angleDegrees: 2.0),
        .helix(rampAngleDegrees: 2.0),
        .fromOpenEnd(stepoverPercentage: 0.4)
    ]
}

extension SC.PocketClearingPattern {

    /// Every pocket pattern, with the parameters a freshly picked one starts with.
    public static let defaults: [SC.PocketClearingPattern] = [
        .offset,
        .concentric(direction: .outsideIn),
        .raster,
        .spiral(direction: .outsideIn),
        .trochoidal(settings: .init(radialEngagement: 0.3, loopRadius: 1.0)),
        .adaptive(settings: .init(optimalLoad: 1.0))
    ]
}

extension SC.SlotClearingPattern {

    /// Every slot pattern, with the parameters a freshly picked one starts with.
    public static let defaults: [SC.SlotClearingPattern] = [
        .raster,
        .trochoidal(settings: .init(radialEngagement: 0.3, loopRadius: 1.0)),
        .adaptive(settings: .init(optimalLoad: 1.0))
    ]
}

// MARK: - Requirements

extension SC.MachiningOperation {

    public var requirements: SC.OperationRequirements {
        // `.fromOpenEnd` is only meaningful where the feature really is open at the start
        // (a slot running off the stock); anywhere else it is just a plunge.
        let closedEntries = SC.EntryStrategy.defaults.filter { entry in
            if case .fromOpenEnd = entry {
                return false
            }
            return true
        }

        switch self {
            case .engrave:
                // A helix would cut a circle next to the start of the line; only a plunge
                // or a ramp along the line itself make sense for an engraving.
                let engraveEntries = closedEntries.filter { entry in
                    if case .helix = entry {
                        return false
                    }
                    return true
                }
                return .init(usesStepdown: true, entries: engraveEntries)

            case .contour(let side, _, _, _, _, _):
                // Stock is left on the side the tool cuts along; on the line there is none.
                return .init(usesStepdown: true,
                             usesAllowance: side != .onContour,
                             usesDirection: true,
                             usesSide: true,
                             usesLeadInOut: true,
                             usesHoldingTabs: true,
                             entries: closedEntries)

            case .pocket(_, let pattern, _):
                // Adaptive clearing is sized by its optimal load; every other pattern
                // steps over by the stepover.
                let usesStepover: Bool
                if case .adaptive = pattern {
                    usesStepover = false
                } else {
                    usesStepover = true
                }
                return .init(usesStepdown: true,
                             usesStepover: usesStepover,
                             usesAllowance: true,
                             usesDirection: true,
                             entries: closedEntries,
                             pocketPatterns: SC.PocketClearingPattern.defaults)

            case .slotting:
                // A slot steps down by its own `depthPerPass`.
                return .init(entries: SC.EntryStrategy.defaults,
                             slotPatterns: SC.SlotClearingPattern.defaults)

            case .facing:
                return .init(usesStepdown: true,
                             usesStepover: true,
                             usesDirection: true)

            case .counterbore:
                return .init(usesEndZ: false,
                             usesStepdown: true,
                             usesStepover: true,
                             usesDirection: true,
                             entries: closedEntries)

            case .chamfer:
                // The depth comes from the width and the V-bit; the side and direction are part
                // of `ChamferParams`.
                return .init(usesEndZ: false,
                             usesDirection: true,
                             usesSide: true)

            case .drilling, .boring, .threadMilling:
                return .init()
        }
    }
}

// MARK: - Reading and writing parameters

extension SC.MachiningOperation {

    /// The cut direction, for the operations that have one (see `requirements.usesDirection`).
    /// Setting it on an operation without one does nothing.
    public var direction: SC.CutDirection? {
        get {
            switch self {
                case .facing(let direction, _): return direction
                case .contour(_, let direction, _, _, _, _): return direction
                case .pocket(let direction, _, _): return direction
                case .counterbore(_, _, let direction, _): return direction
                case .chamfer(let params): return params.direction
                case .slotting, .threadMilling, .engrave, .drilling, .boring: return nil
            }
        }
        set {
            guard let newValue else {
                return
            }
            switch self {
                case .facing(_, let extensionLength):
                    self = .facing(direction: newValue, extensionLength: extensionLength)
                case .contour(let side, _, let entry, let leadIn, let leadOut, let tabs):
                    self = .contour(side: side, direction: newValue, entry: entry, leadIn: leadIn, leadOut: leadOut, tabs: tabs)
                case .pocket(_, let pattern, let entry):
                    self = .pocket(direction: newValue, pattern: pattern, entry: entry)
                case .counterbore(let diameter, let depth, _, let entry):
                    self = .counterbore(diameter: diameter, depth: depth, direction: newValue, entry: entry)
                case .chamfer(var params):
                    params.direction = newValue
                    self = .chamfer(params: params)
                case .slotting, .threadMilling, .engrave, .drilling, .boring:
                    break
            }
        }
    }

    /// The entry strategy, for the operations that have one (see `requirements.usesEntry`).
    /// Setting it on an operation without one does nothing.
    public var entry: SC.EntryStrategy? {
        get {
            switch self {
                case .slotting(_, _, let entry): return entry
                case .contour(_, _, let entry, _, _, _): return entry
                case .pocket(_, _, let entry): return entry
                case .counterbore(_, _, _, let entry): return entry
                case .engrave(let entry): return entry
                case .facing, .threadMilling, .drilling, .chamfer, .boring: return nil
            }
        }
        set {
            guard let newValue else {
                return
            }
            switch self {
                case .slotting(let depthPerPass, let pattern, _):
                    self = .slotting(depthPerPass: depthPerPass, pattern: pattern, entry: newValue)
                case .contour(let side, let direction, _, let leadIn, let leadOut, let tabs):
                    self = .contour(side: side, direction: direction, entry: newValue, leadIn: leadIn, leadOut: leadOut, tabs: tabs)
                case .pocket(let direction, let pattern, _):
                    self = .pocket(direction: direction, pattern: pattern, entry: newValue)
                case .counterbore(let diameter, let depth, let direction, _):
                    self = .counterbore(diameter: diameter, depth: depth, direction: direction, entry: newValue)
                case .engrave:
                    self = .engrave(entry: newValue)
                case .facing, .threadMilling, .drilling, .chamfer, .boring:
                    break
            }
        }
    }
}

// MARK: - Validation

extension SC.MachiningOperation {

    /// Checks the operation's own values, and how they combine, against `tool`, before any
    /// geometry is involved.
    ///
    /// - Throws: `SC.Error.invalidParameter` naming the first value that can't be used (by its
    ///   `ParameterField` id, e.g. `"pattern.adaptive.optimalLoad"`), or
    ///   `SC.Error.toolIncompatible` when the tool can't do the cut at all.
    public func validate(tool: SC.ToolParams) throws {
        func require(_ condition: Bool, parameter: String) throws {
            guard condition else {
                throw SC.Error.invalidParameter(parameter)
            }
        }

        // The entry strategy has to be one the operation accepts.
        if let chosen = self.entry {
            try require(requirements.accepts(chosen), parameter: "entry")
        }

        switch self {

            case .engrave:
                // The entry was already checked above against `requirements.entries`.
                break

            case .contour(_, _, let entry, let leadIn, _, _):
                // The lead-in is the approach move the tool plunges at; a ramp or helix entry
                // is its own approach, so the two can't be combined (a lead-out always can).
                if leadIn != nil {
                    switch entry {
                        case .ramp, .helix:
                            throw SC.Error.invalidParameter("contour.leadIn")
                        case .plunge, .fromOpenEnd:
                            break
                    }
                }

            case .pocket(_, let pattern, _):
                switch pattern {
                    case .trochoidal(let settings):
                        // Below ~5 % the loops get so tight that the path explodes in size.
                        try require(settings.radialEngagement >= 0.05 - 1e-9 && settings.radialEngagement <= 1 + 1e-9,
                                    parameter: "pattern.trochoidal.radialEngagement")

                    case .adaptive(let settings):
                        // The engine clamps to 2 %...95 % of the diameter; refuse what clamping
                        // would silently change.
                        try require(settings.optimalLoad > 0
                                        && (tool.diameter <= 0 || settings.optimalLoad <= 0.95 * tool.diameter),
                                    parameter: "pattern.adaptive.optimalLoad")

                    case .offset, .concentric, .raster, .spiral:
                        break
                }

            case .facing(_, let extensionLength):
                try require(extensionLength >= 0, parameter: "facing.extensionLength")

            case .slotting(let depthPerPass, _, _):
                try require(depthPerPass > 0, parameter: "slotting.depthPerPass")

            case .drilling(let peckDepth):
                if let peckDepth {
                    try require(peckDepth > 0, parameter: "drilling.peckDepth")
                }

            case .counterbore(let diameter, let depth, _, _):
                try require(depth > 0, parameter: "counterbore.depth")
                guard diameter > tool.diameter else {
                    throw SC.Error.toolIncompatible
                }

            case .boring(let targetDiameter, let dwellTime, _):
                try require(targetDiameter > 0, parameter: "boring.targetDiameter")
                if let dwellTime {
                    try require(dwellTime >= 0, parameter: "boring.dwellTime")
                }

            case .threadMilling(let pitch, _, _, let radialPasses, let targetDiameter):
                try require(pitch > 0, parameter: "threadMilling.pitch")
                try require(targetDiameter > 0, parameter: "threadMilling.targetDiameter")
                try require(radialPasses >= 1, parameter: "threadMilling.radialPasses")

            case .chamfer(let params):
                try require(params.width > 0, parameter: "chamfer.params.width")
                if let depth = params.depth {
                    try require(depth > 0, parameter: "chamfer.params.depth")
                } else if (tool.vAngle ?? 0) <= 0 {
                    // Without a fixed depth the depth comes from the V-bit's included angle.
                    throw SC.Error.toolIncompatible
                }
        }
    }
}
