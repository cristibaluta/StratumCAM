//
//  CAMEngine.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 10.09.2026.
//

import Foundation
import simd

public final class SCEngine {

    public init() {}

    /// Generates toolpaths for the given strategy. Each contour becomes zero or one
    /// `OutputToolpath` depending on whether the strategy has anything machinable to say
    /// about it (e.g. `.drilling` on a non-point contour currently yields nothing).
    ///
    /// `strategy` defaults to `.engrave`, which traces the geometry exactly at cutter-center
    /// (no tool-radius compensation) -- the classic engraving / center-line cutting case.
    ///
    /// `throws` as of Step 6.2, extended in 6.3 (`.chamfer`, `.boring`), 6.4
    /// (`.engrave`, `.profile` -- both share `buildContourTracingToolpath`/
    /// `buildContourToolpath`'s pipeline, so `.engrave` starts throwing here too even
    /// though 6.4 is nominally `.profile`'s step), 6.5 (`.counterbore`), and 6.6
    /// (`.threadMilling`). Every other operation still returns `nil` for "nothing
    /// machinable" exactly as before until its own step in the roadmap converts it. A
    /// thrown error aborts the whole batch rather than skipping just the offending
    /// contour -- see the doc comment on `buildToolpath` below for why that's the
    /// intended behavior change, not a bug.
    public func generateToolpaths(from contours: [SC.Contour],
                                  tool: SC.ToolParams,
                                  settings: SC.MachineSettings,
                                  operation: SC.MachiningOperation) throws -> [SC.OutputToolpath] {

        var results: [SC.OutputToolpath] = []

        for contour in contours {
            if let toolpath = try buildToolpath(for: contour, tool: tool, settings: settings, operation: operation) {
                results.append(toolpath)
            }
        }

        return results
    }

    /// Generates facing toolpaths, one per `FacingOperation`. `.facing` has no
    /// selected contour to iterate -- it clears a `Stock`'s whole top-face footprint
    /// once -- so it can't go through the per-contour `buildToolpath` switch below
    /// the way every other strategy does (see `FacingOperation`'s doc comment and
    /// Step 2A.1's flag on this exact gap). This is a dedicated overload for that
    /// signature mismatch. Drilling doesn't need an equivalent: a hole is just a
    /// contour like any other strategy's, so a batch of holes -- even ones that mix
    /// tools, settings, or peck depths -- is just repeated calls to `buildToolpath`
    /// below (now `public` for exactly this reason) rather than its own wrapper type.
    public func generateToolpaths(from operations: [SC.FacingOperation]) throws -> [SC.OutputToolpath] {
        try operations.compactMap { operation in
            try buildFacingToolpath(
                stock: operation.stock,
                tool: operation.tool,
                settings: operation.settings,
                direction: operation.direction,
                extensionLength: operation.extensionLength,
                operation: .facing(direction: operation.direction,
                                   extensionLength: operation.extensionLength)
            )
        }
    }

    // MARK: - Strategy dispatch

    /// Routes a single contour to the builder for its strategy. Returns `nil` when the
    /// contour has nothing machinable (e.g. an empty/degenerate contour) or -- for now --
    /// when the strategy's real geometry isn't implemented yet (see TODOs below).
    ///
    /// `throws` as of Step 6.2, extended in 6.3, 6.4, 6.5, and 6.6 -- `.drilling`,
    /// `.chamfer`, `.boring`, `.engrave`, `.profile`, `.counterbore`, and
    /// `.threadMilling` now throw (see `buildDrillingToolpath`/`buildChamferToolpath`/
    /// `buildBoringToolpath`/`buildContourTracingToolpath`/`buildContourToolpath`/
    /// `buildCounterboreToolpath`/`buildThreadMillingToolpath`) -- every other case
    /// below still returns `nil` unchanged, converting one operation at a time per the
    /// roadmap. Note the difference in what
    /// `nil` vs. a thrown error means to the caller: `nil` here means "this one contour
    /// had nothing machinable," and the batch overloads above skip it and keep going;
    /// a thrown error means "this input was actually wrong," and the batch overloads
    /// let it propagate and abort the whole call rather than silently dropping the
    /// offending contour from the results.
    ///
    /// `public` (rather than the batch-oriented `generateToolpaths` above) so a caller
    /// that needs per-call tool/settings/operation -- e.g. a batch of holes where each
    /// one has its own drill tool, machine settings, or peck depth -- can just call this
    /// once per contour directly instead of going through a dedicated wrapper type.
    public func buildToolpath(for contour: SC.Contour,
                              tool: SC.ToolParams,
                              settings: SC.MachineSettings,
                              operation: SC.MachiningOperation) throws -> SC.OutputToolpath? {
        switch operation {
            case .engrave:
                return try buildContourTracingToolpath(for: contour,
                                                       tool: tool,
                                                       settings: settings,
                                                       side: .onContour,
                                                       operation: operation)

            case .contour(let side, let direction, let entry, let leadIn, let leadOut, let tabs):
                return try buildContourToolpath(for: contour,
                                                tool: tool,
                                                settings: settings,
                                                side: side,
                                                direction: direction,
                                                entry: entry,
                                                leadIn: leadIn,
                                                leadOut: leadOut,
                                                tabs: tabs,
                                                operation: operation)

            case .chamfer(let params):
                return try buildChamferToolpath(for: contour,
                                                tool: tool,
                                                settings: settings,
                                                params: params,
                                                operation: operation)

            case .drilling(let peckDepth):
                return try buildDrillingToolpath(for: contour,
                                                 tool: tool,
                                                 settings: settings,
                                                 peckDepth: peckDepth,
                                                 operation: operation)

            case .pocket(let direction, let pattern, let entry):
                return try buildPocketToolpath(for: contour,
                                               tool: tool,
                                               settings: settings,
                                               direction: direction,
                                               pattern: pattern,
                                               entry: entry,
                                               operation: operation
                )

            case .facing:
                print("Use `generateToolpaths(from operations: [SC.FacingOperation])` instead.")
                return nil

            case .slotting(let depthPerPass, let pattern, let entry):
                return try buildSlottingToolpath(for: contour,
                                                 tool: tool,
                                                 settings: settings,
                                                 pattern: pattern,
                                                 depthPerPass: depthPerPass,
                                                 entry: entry,
                                                 operation: operation)

            case .threadMilling(pitch: let pitch,
                                isInternal: let isInternal,
                                direction: let direction,
                                radialPasses: let radialPasses,
                                targetDiameter: let targetDiameter):

                return try buildThreadMillingToolpath(for: contour,
                                                      tool: tool,
                                                      settings: settings,
                                                      pitch: pitch,
                                                      isInternal: isInternal,
                                                      direction: direction,
                                                      radialPasses: radialPasses,
                                                      targetDiameter: targetDiameter,
                                                      operation: operation)

            case .boring(targetDiameter: let targetDiameter, dwellTime: _, shiftRetract: let shiftRetract):
                // dwellTime doesn't touch the waypoints -- it's a G-code-only concern
                // handled by SCGCodeEngine reading it straight off `operation` (Step 2C.2).
                return try buildBoringToolpath(for: contour,
                                               tool: tool,
                                               settings: settings,
                                               targetDiameter: targetDiameter,
                                               shiftRetract: shiftRetract,
                                               operation: operation)

            case .counterbore(let diameter, let depth, let direction, let entry):
                return try buildCounterboreToolpath(for: contour,
                                                    tool: tool,
                                                    settings: settings,
                                                    diameter: diameter,
                                                    depth: depth,
                                                    direction: direction,
                                                    entry: entry,
                                                    operation: operation)
        }
    }

    public func buildWaypoints(for segments: [SC.Segment], atZ z: Double, settings: SC.MachineSettings) -> [SC.Waypoint] {
        var waypoints: [SC.Waypoint] = []

        guard let first = segments.first else {
            return []
        }
        let startPoint = first.startPoint

        // TODO: should the plunge be moved to buildEntryWaypoints?

        // 1. Rapid move above start point at Safe Z
        waypoints.append(SC.Waypoint(position: SIMD3(startPoint.x, startPoint.y, settings.safeZ),
                                     motion: .rapid,
                                     feedRate: settings.cutting.feedRate))

        // TODO: should be an intermediate step with retractZ?

        // 2. Plunge down to target Z
        waypoints.append(SC.Waypoint(position: SIMD3(startPoint.x, startPoint.y, z),
                                     motion: .linear,
                                     feedRate: settings.cutting.plungeRate))

        // 3. Trace segments along XY plane
        for segment in segments {
            switch segment {
                case .line(_, let end):
                    waypoints.append(SC.Waypoint(position: SIMD3(end.x, end.y, z),
                                                 motion: .linear,
                                                 feedRate: settings.cutting.feedRate))

                case .arc(let center, let radius, _, let endAngle, let isCCW):
                    // Compute end position using radius and radian end angle
                    let endX = center.x + radius * cos(endAngle)
                    let endY = center.y + radius * sin(endAngle)
                    let motion: SC.MotionType = isCCW ? .arcCCW(center: center) : .arcCW(center: center)

                    waypoints.append(SC.Waypoint(position: SIMD3(endX, endY, z),
                                                 motion: motion,
                                                 feedRate: settings.cutting.feedRate))
            }
        }

        // 4. Retract back to Safe Z after contour completion
        if let lastPoint = waypoints.last?.position {
            waypoints.append(SC.Waypoint(position: SIMD3(lastPoint.x, lastPoint.y, settings.safeZ),
                                         motion: .rapid,
                                         feedRate: settings.cutting.feedRate))
        }

        return waypoints
    }
}
