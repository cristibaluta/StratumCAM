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
//   - `validate(tool:)` whether the values it carries (and their combinations) are usable
//   - `direction`, `entry`, ... read and write a parameter without switching over every case
//

import Foundation

extension SC {

    /// The kind of an `EntryStrategy`, without its parameters.
    public enum EntryKind: String, Sendable, Codable, CaseIterable, Equatable {
        case plunge
        case ramp
        case helix
        case fromOpenEnd
    }

    /// The kind of a pocket or slot clearing pattern, without its parameters.
    public enum ClearingPatternKind: String, Sendable, Codable, CaseIterable, Equatable {
        case offset
        case concentric
        case raster
        case spiral
        case trochoidal
        case adaptive
    }

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

        // MARK: Parameters of the operation itself

        /// The operation has a climb / conventional direction.
        public var usesDirection: Bool

        /// The operation has a cut side (inside / outside / on the line) of its own.
        public var usesSide: Bool

        /// The operation takes a lead-in and a lead-out.
        public var usesLeadInOut: Bool

        /// The operation takes holding tabs.
        public var usesHoldingTabs: Bool

        /// The entry strategies the operation accepts, in the order they should be offered.
        /// Empty when it has no entry strategy at all.
        public var entryKinds: [EntryKind]

        /// The clearing patterns the operation accepts, in the order they should be offered.
        /// Empty when it has no clearing pattern at all.
        public var clearingPatterns: [ClearingPatternKind]

        /// The operation has an entry strategy.
        public var usesEntry: Bool {
            !entryKinds.isEmpty
        }

        /// The operation has a clearing pattern.
        public var usesClearingPattern: Bool {
            !clearingPatterns.isEmpty
        }

        public init(usesEndZ: Bool = true,
                    usesStepdown: Bool = false,
                    usesStepover: Bool = false,
                    usesDirection: Bool = false,
                    usesSide: Bool = false,
                    usesLeadInOut: Bool = false,
                    usesHoldingTabs: Bool = false,
                    entryKinds: [EntryKind] = [],
                    clearingPatterns: [ClearingPatternKind] = []) {
            self.usesEndZ = usesEndZ
            self.usesStepdown = usesStepdown
            self.usesStepover = usesStepover
            self.usesDirection = usesDirection
            self.usesSide = usesSide
            self.usesLeadInOut = usesLeadInOut
            self.usesHoldingTabs = usesHoldingTabs
            self.entryKinds = entryKinds
            self.clearingPatterns = clearingPatterns
        }
    }

    /// An operation parameter, or the tool it will run with, that the engine can't work with.
    ///
    /// `parameter` is a stable id for the offending value (it matches the `ParameterField`
    /// ids where there is one, e.g. `"pattern.adaptive.optimalLoad"`), so a caller can point at
    /// the right control. `message` is written to be shown to the user as it is.
    public struct ValidationIssue: Swift.Error, LocalizedError, Sendable, Equatable {
        public var parameter: String
        public var message: String

        public init(parameter: String, message: String) {
            self.parameter = parameter
            self.message = message
        }

        public var errorDescription: String? {
            message
        }
    }
}

// MARK: - Kinds

extension SC.EntryStrategy {

    public var kind: SC.EntryKind {
        switch self {
            case .plunge: return .plunge
            case .ramp: return .ramp
            case .helix: return .helix
            case .fromOpenEnd: return .fromOpenEnd
        }
    }
}

extension SC.PocketClearingPattern {

    public var kind: SC.ClearingPatternKind {
        switch self {
            case .offset: return .offset
            case .concentric: return .concentric
            case .raster: return .raster
            case .spiral: return .spiral
            case .trochoidal: return .trochoidal
            case .adaptive: return .adaptive
        }
    }
}

extension SC.SlotClearingPattern {

    public var kind: SC.ClearingPatternKind {
        switch self {
            case .raster: return .raster
            case .trochoidal: return .trochoidal
            case .adaptive: return .adaptive
        }
    }
}

// MARK: - Requirements

extension SC.MachiningOperation {

    public var requirements: SC.OperationRequirements {
        // `.fromOpenEnd` is only meaningful where the feature really is open at the start
        // (a slot running off the stock); anywhere else it is just a plunge.
        let closedEntries: [SC.EntryKind] = [.plunge, .ramp, .helix]

        switch self {
            case .engrave:
                return .init(usesStepdown: true)

            case .contour:
                return .init(usesStepdown: true,
                             usesDirection: true,
                             usesSide: true,
                             usesLeadInOut: true,
                             usesHoldingTabs: true,
                             entryKinds: closedEntries)

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
                             usesDirection: true,
                             entryKinds: closedEntries,
                             clearingPatterns: [.offset, .concentric, .raster, .spiral, .trochoidal, .adaptive])

            case .slotting:
                // A slot steps down by its own `depthPerPass`.
                return .init(entryKinds: SC.EntryKind.allCases,
                             clearingPatterns: [.raster, .trochoidal, .adaptive])

            case .facing:
                return .init(usesDirection: true)

            case .counterbore:
                return .init(usesEndZ: false,
                             usesStepdown: true,
                             usesStepover: true,
                             usesDirection: true,
                             entryKinds: closedEntries)

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
                case .facing, .threadMilling, .engrave, .drilling, .chamfer, .boring: return nil
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
                case .facing, .threadMilling, .engrave, .drilling, .chamfer, .boring:
                    break
            }
        }
    }

    /// The kind of clearing pattern, for the operations that have one
    /// (see `requirements.usesClearingPattern`).
    public var clearingPatternKind: SC.ClearingPatternKind? {
        switch self {
            case .pocket(_, let pattern, _): return pattern.kind
            case .slotting(_, let pattern, _): return pattern.kind
            case .facing, .contour, .threadMilling, .engrave, .drilling, .chamfer, .boring, .counterbore: return nil
        }
    }
}

// MARK: - Validation

extension SC.MachiningOperation {

    /// Checks the operation's own values, and how they combine, against `tool`, before any
    /// geometry is involved.
    ///
    /// - Throws: `SC.ValidationIssue` for the first value that can't be used.
    public func validate(tool: SC.ToolParams) throws {
        func require(_ condition: Bool, _ parameter: String, _ message: @autoclosure () -> String) throws {
            guard condition else {
                throw SC.ValidationIssue(parameter: parameter, message: message())
            }
        }

        // The entry strategy has to be one the operation accepts.
        if let chosen = self.entry {
            try require(requirements.entryKinds.contains(chosen.kind),
                        "entry",
                        "This operation can't use a \(chosen.kind.rawValue) entry.")
        }

        switch self {

            case .engrave:
                break

            case .contour(_, _, let entry, let leadIn, _, _):
                // The lead-in is the approach move the tool plunges at; a ramp or helix entry
                // is its own approach, so the two can't be combined (a lead-out always can).
                if leadIn != nil {
                    switch entry {
                        case .ramp, .helix:
                            try require(false,
                                        "contour.leadIn",
                                        "A lead-in can't be combined with a ramp or helix entry: the entry already eases the tool in.")
                        case .plunge, .fromOpenEnd:
                            break
                    }
                }

            case .pocket(_, let pattern, _):
                switch pattern {
                    case .trochoidal(let settings):
                        // Below ~5 % the loops get so tight that the path explodes in size.
                        try require(settings.radialEngagement >= 0.05 - 1e-9 && settings.radialEngagement <= 1 + 1e-9,
                                    "pattern.trochoidal.radialEngagement",
                                    "The trochoidal loop pitch must be between 5 % and 100 % of the tool radius.")

                    case .adaptive(let settings):
                        try require(settings.optimalLoad > 0,
                                    "pattern.adaptive.optimalLoad",
                                    "The adaptive optimal load must be greater than 0.")
                        // The engine clamps to 2 %...95 % of the diameter; refuse what clamping
                        // would silently change.
                        try require(tool.diameter <= 0 || settings.optimalLoad <= 0.95 * tool.diameter,
                                    "pattern.adaptive.optimalLoad",
                                    "The adaptive optimal load can't exceed 95 % of the tool diameter.")

                    case .offset, .concentric, .raster, .spiral:
                        break
                }

            case .facing(_, let extensionLength):
                try require(extensionLength >= 0,
                            "facing.extensionLength",
                            "The facing extension can't be negative.")

            case .slotting(let depthPerPass, _, _):
                try require(depthPerPass > 0,
                            "slotting.depthPerPass",
                            "Depth per pass must be greater than 0.")

            case .drilling(let peckDepth):
                if let peckDepth {
                    try require(peckDepth > 0,
                                "drilling.peckDepth",
                                "The peck depth must be greater than 0.")
                }

            case .counterbore(let diameter, let depth, _, _):
                try require(depth > 0,
                            "counterbore.depth",
                            "The counterbore depth must be greater than 0.")
                try require(diameter > tool.diameter,
                            "counterbore.diameter",
                            "The counterbore diameter must be larger than the tool (Ø\(tool.diameter) mm).")

            case .boring(let targetDiameter, let dwellTime, _):
                try require(targetDiameter > 0,
                            "boring.targetDiameter",
                            "The finished diameter must be greater than 0.")
                if let dwellTime {
                    try require(dwellTime >= 0,
                                "boring.dwellTime",
                                "The dwell time can't be negative.")
                }

            case .threadMilling(let pitch, _, _, let radialPasses, let targetDiameter):
                try require(pitch > 0,
                            "threadMilling.pitch",
                            "The thread pitch must be greater than 0.")
                try require(targetDiameter > 0,
                            "threadMilling.targetDiameter",
                            "The thread diameter must be greater than 0.")
                try require(radialPasses >= 1,
                            "threadMilling.radialPasses",
                            "The thread needs at least 1 radial pass.")

            case .chamfer(let params):
                try require(params.width > 0,
                            "chamfer.params.width",
                            "The chamfer width must be greater than 0.")
                if let depth = params.depth {
                    try require(depth > 0,
                                "chamfer.params.depth",
                                "The chamfer depth must be greater than 0.")
                } else {
                    // Without a fixed depth the depth comes from the V-bit's included angle.
                    try require((tool.vAngle ?? 0) > 0,
                                "chamfer.params.depth",
                                "A chamfer needs a V-bit: pick a tool with a tip angle, or give the chamfer a fixed depth.")
                }
        }
    }
}
