//
//  SCPostEngine.swift
//  StratumCAM
//
//  Runs a Fusion-style `.cps` post processor (Makera's Carvera.cps) inside JavaScriptCore.
//
//  Pipeline:
//    [SC.OutputToolpath] --> job dictionary --> JSON --> JSContext
//        1. `__job` is parsed from JSON
//        2. SCPostKernel.js  (emulates the Autodesk post-kernel API)
//        3. Carvera.cps      (the unmodified post)
//        4. __run() plays the job through onOpen / onSection / onLinear / ... / onClose
//        5. __collect() returns the generated files + diagnostics as JSON
//
//  A fresh JSContext is created per call, because the post keeps state in globals
//  (current tool, modal G/M words, split-file counters, ...).
//

import Foundation
import JavaScriptCore

public struct SCPostEngine {

    // MARK: - Public model

    /// Tool data the post needs (tool number for `T1M6`, diameter for the header comment, ...).
    /// `SC.OutputToolpath` doesn't appear to carry this, so the caller supplies it per toolpath.
    public struct Tool {

        /// Order matches the constants in SCPostKernel.js.
        public enum Kind: Int {
            case unspecified = 0, drill, flatEndMill, ballEndMill, bullNoseEndMill,
                 chamferMill, engraving, faceMill, probe, laserCutter
        }

        public var number: Int
        public var diameter: Double
        public var name: String
        /// Carvera.cps reads this: e.g. "TLO:A" / "TLO:M" / "TLO:-14", or extra `M6` parameters
        /// when the community-firmware properties are enabled.
        public var comment: String
        public var kind: Kind
        public var clockwise: Bool
        public var shaftDiameter: Double?
        public var manualToolChange: Bool

        public init(number: Int = 1,
                    diameter: Double = 0,
                    name: String = "",
                    comment: String = "",
                    kind: Kind = .flatEndMill,
                    clockwise: Bool = true,
                    shaftDiameter: Double? = nil,
                    manualToolChange: Bool = false) {
            self.number = number
            self.diameter = diameter
            self.name = name
            self.comment = comment
            self.kind = kind
            self.clockwise = clockwise
            self.shaftDiameter = shaftDiameter
            self.manualToolChange = manualToolChange
        }

        public static let generic = Tool(name: "StratumCAM tool")

        fileprivate var jsonObject: [String: Any] {
            var object: [String: Any] = [
                "number": number,
                "diameter": diameter,
                "description": name,
                "comment": comment,
                "type": kind.rawValue,
                "clockwise": clockwise,
                "manualToolChange": manualToolChange
            ]
            if let shaftDiameter { object["shaftDiameter"] = shaftDiameter }
            return object
        }
    }

    /// Optional stock extents (Z, relative to the work origin). Only used for the informational
    /// "Z Origin Set To ..." comment block that Carvera.cps writes in the header.
    public struct Stock {
        public var zHigh: Double
        public var zLow: Double
        public init(zHigh: Double, zLow: Double) {
            self.zHigh = zHigh
            self.zLow = zLow
        }
    }

    public struct Diagnostic {
        public enum Severity: String { case warning, error }
        public let severity: Severity
        public let message: String
    }

    public struct OutputFile {
        public let name: String
        public let gcode: String
    }

    public struct Output {
        /// The main program. With `splitFile` enabled this only holds a stub comment.
        public let gcode: String
        /// Extra files produced when the post's `splitFile` property is "tool" or "toolpath".
        public let additionalFiles: [OutputFile]
        /// Messages from the post's `error()` / `warning()` calls.
        public let diagnostics: [Diagnostic]

        public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
    }

    public enum PostError: Error, LocalizedError {
        case resourceNotFound(String)
        case invalidJob
        case scriptError(String)
        case malformedResult

        public var errorDescription: String? {
            switch self {
                case .resourceNotFound(let name): return "Post processor resource not found: \(name)"
                case .invalidJob: return "The job could not be serialized to JSON (NaN or infinite value?)."
                case .scriptError(let message): return "Post processor script error: \(message)"
                case .malformedResult: return "The post processor returned an unreadable result."
            }
        }
    }

    // MARK: - Configuration

    /// Post properties, keyed by the property names in the .cps `properties` block
    /// (e.g. `"manualToolChangeBehavior": "carvcomMtc"`, `"splitFile": "tool"`).
    /// Values must be JSON-compatible (Bool, Int, Double, String).
    public var properties: [String: Any]

    public var stock: Stock?

    private let postSource: String
    private let kernelSource: String

    // MARK: - Init

    public init(postSource: String, kernelSource: String, properties: [String: Any] = [:], stock: Stock? = nil) {
        self.postSource = postSource
        self.kernelSource = kernelSource
        self.properties = properties
        self.stock = stock
    }

    /// Loads `Carvera.cps` and `SCPostKernel.js` from a bundle (add both to "Copy Bundle Resources").
    /// For a Swift package target pass `Bundle.module`.
    public init(bundle: Bundle = .main,
                postName: String = "Carvera",
                postExtension: String = "cps",
                kernelName: String = "SCPostKernel",
                properties: [String: Any] = [:],
                stock: Stock? = nil) throws {

        func load(_ name: String, _ ext: String) throws -> String {
            guard let url = bundle.url(forResource: name, withExtension: ext) else {
                throw PostError.resourceNotFound("\(name).\(ext)")
            }
            return try String(contentsOf: url, encoding: .utf8)
        }

        self.init(postSource: try load(postName, postExtension),
                  kernelSource: try load(kernelName, "js"),
                  properties: properties,
                  stock: stock)
    }

    // MARK: - Generation

    /// Drop-in replacement for `SCGCodeEngine.generateGCode(from:settings:)`.
    /// Failures are returned as a G-code comment; use `generate(...)` to get typed errors and diagnostics.
    public func generateGCode(from toolpaths: [SC.OutputToolpath], settings: SC.MachineSettings) -> String {
        do {
            return try generate(from: toolpaths, settings: settings).gcode
        } catch {
            return "(Post processing failed: \(error.localizedDescription))"
        }
    }

    /// Runs the post. Each `OutputToolpath` becomes one post "section" (one operation).
    public func generate(from toolpaths: [SC.OutputToolpath],
                         settings: SC.MachineSettings,
                         programName: String = "StratumCAM",
                         toolProvider: (SC.OutputToolpath) -> Tool = { _ in .generic }) throws -> Output {

        let job = makeJob(from: toolpaths, programName: programName, toolProvider: toolProvider)

        guard JSONSerialization.isValidJSONObject(job),
              let jobData = try? JSONSerialization.data(withJSONObject: job),
              let jobJSON = String(data: jobData, encoding: .utf8) else {
            throw PostError.invalidJob
        }

        guard let context = JSContext() else {
            throw PostError.scriptError("Unable to create a JavaScript context.")
        }

        var exceptions: [String] = []
        context.exceptionHandler = { _, exception in
            exceptions.append(exception?.toString() ?? "Unknown JavaScript exception")
        }

        func evaluate(_ script: String, named name: String) throws {
            context.evaluateScript(script, withSourceURL: URL(fileURLWithPath: name))
            if !exceptions.isEmpty {
                throw PostError.scriptError("\(name): " + exceptions.joined(separator: "\n"))
            }
        }

        context.setObject(jobJSON, forKeyedSubscript: "__jobJSON" as NSString)
        try evaluate("var __job = JSON.parse(__jobJSON);", named: "job")
        try evaluate(kernelSource, named: "SCPostKernel.js")
        try evaluate(postSource, named: "Carvera.cps")
        try evaluate("__run();", named: "run")

        guard let resultJSON = context.evaluateScript("__collect();")?.toString(),
              let resultData = resultJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
              let rawFiles = root["files"] as? [[String: Any]] else {
            throw PostError.malformedResult
        }

        let files: [OutputFile] = rawFiles.map {
            OutputFile(name: $0["path"] as? String ?? "", gcode: $0["text"] as? String ?? "")
        }

        let diagnostics: [Diagnostic] = (root["diagnostics"] as? [[String: Any]] ?? []).compactMap {
            guard let message = $0["message"] as? String else { return nil }
            let severity = Diagnostic.Severity(rawValue: $0["severity"] as? String ?? "") ?? .warning
            return Diagnostic(severity: severity, message: message)
        }

        return Output(gcode: files.first?.gcode ?? "",
                      additionalFiles: Array(files.dropFirst()),
                      diagnostics: diagnostics)
    }

    // MARK: - Job construction

    private func makeJob(from toolpaths: [SC.OutputToolpath],
                         programName: String,
                         toolProvider: (SC.OutputToolpath) -> Tool) -> [String: Any] {

        var sections: [[String: Any]] = []

        for (toolpathIndex, toolpath) in toolpaths.enumerated() {

            // Same rule as SCGCodeEngine: boring's dwell belongs after the last arc of each pass.
            let boringDwellTime: Double? = {
                if case .boring(_, let dwellTime, _) = toolpath.operation {
                    return dwellTime
                }
                return nil
            }()

            var moves: [[String: Any]] = []

            for pass in toolpath.passes {

                moves.append(["t": "comment", "text": "--- Pass Depth: \(pass.depthZ) ---"])

                let lastArcIndex = pass.waypoints.lastIndex { waypoint in
                    switch waypoint.motion {
                        case .arcCW, .arcCCW: return true
                        default: return false
                    }
                }

                for (index, waypoint) in pass.waypoints.enumerated() {

                    moves.append(moveObject(for: waypoint))

                    if let boringDwellTime, boringDwellTime > 0, index == lastArcIndex {
                        moves.append(["t": "dwell", "seconds": boringDwellTime])
                    }
                }
            }

            sections.append([
                "comment": sectionName(for: toolpath, index: toolpathIndex),
                "workOffset": 1,
                "spindleSpeed": Double(toolpath.settings.cutting.spindleSpeed),
                "tool": toolProvider(toolpath).jsonObject,
                "moves": moves
            ])
        }

        var job: [String: Any] = [
            "unit": "mm",
            "programName": programName,
            "properties": properties,
            "sections": sections
        ]
        if let stock {
            job["stock"] = ["zHigh": stock.zHigh, "zLow": stock.zLow]
        }
        return job
    }

    private func sectionName(for toolpath: SC.OutputToolpath, index: Int) -> String {
        if case .drilling = toolpath.operation { return "Drilling \(index + 1)" }
        if case .boring = toolpath.operation { return "Boring \(index + 1)" }
        return "Toolpath \(index + 1)"
    }

    private func moveObject(for waypoint: SC.Waypoint) -> [String: Any] {

        let x = Double(waypoint.position.x)
        let y = Double(waypoint.position.y)
        let z = Double(waypoint.position.z)
        let feed = Double(waypoint.feedRate)

        switch waypoint.motion {

            case .rapid:
                return ["t": "rapid", "x": x, "y": y, "z": z]

            case .linear:
                return ["t": "linear", "x": x, "y": y, "z": z, "f": feed]

            // The post takes the arc centre in absolute coordinates and derives I/J relative to the
            // arc's START point itself (it tracks the current position), so pass the centre as is.
            case .arcCW(let center):
                return ["t": "arc", "cw": true,
                        "cx": Double(center.x), "cy": Double(center.y),
                        "x": x, "y": y, "z": z, "f": feed]

            case .arcCCW(let center):
                return ["t": "arc", "cw": false,
                        "cx": Double(center.x), "cy": Double(center.y),
                        "x": x, "y": y, "z": z, "f": feed]
        }
    }
}
