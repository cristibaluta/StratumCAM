//
//  SCEngine+Allowance.swift
//  StratumCAM
//
//  Stock to leave and the finishing pass (`MachineSettings.allowance` / `.finishingPass`).
//
//  Roughing that leaves stock is the same toolpath as the plain one, just kept `allowance`
//  further from every wall. A cutter of radius `r + allowance` does exactly that: its centre
//  path is the wall offset by `r + allowance`, so each pattern (offset, concentric, raster,
//  spiral, trochoidal, adaptive, the island handling, a contour's side and tabs) gets the
//  stock for free, with no change inside any of them. The output is then given back its real
//  tool. What that stand-in changes besides the distance to the walls is compensated below:
//  the stepover and the trochoidal pitch are fractions of the diameter / radius, so they are
//  scaled to keep their size in mm.
//

import Foundation

extension SCEngine {

    /// Builds `operation` on `contour` so that `settings.allowance` mm of stock stands on the
    /// walls (and, for a pocket, on the floor), then, when `settings.finishingPass` is on,
    /// cuts that stock away.
    ///
    /// Only called for operations whose `requirements.usesAllowance` is true: `.pocket` and a
    /// `.contour` cut on one side of the line.
    ///
    /// - Throws: `SC.Error.invalidParameter("allowance.depth")` when a pocket's depth isn't
    ///   more than the stock left on its floor, and whatever the underlying builders throw.
    ///   A shape narrower than the tool plus the stock on both walls collapses in the roughing
    ///   (`SC.Error.geometryCollapsed`), as a shape narrower than the tool does without stock.
    func buildToolpathLeavingStock(for contour: SC.Contour,
                                   tool: SC.ToolParams,
                                   settings: SC.MachineSettings,
                                   operation: SC.MachiningOperation) throws -> SC.OutputToolpath? {

        let allowance = settings.allowance
        let fullDepth = abs(settings.targetDepth)

        // A pocket leaves its floor too; a contour cuts all the way through.
        var leavesFloor = false
        if case .pocket = operation {
            leavesFloor = true
        }
        if leavesFloor, allowance >= fullDepth - 1e-9 {
            throw SC.Error.invalidParameter("allowance.depth")
        }

        // MARK: Roughing

        var roughTool = tool
        roughTool.diameter = tool.diameter + 2 * allowance

        var roughSettings = settings
        roughSettings.allowance = 0
        roughSettings.finishingPass = false
        // Same stepover in mm, not the same fraction of a wider tool.
        roughSettings.cutting.stepoverPercentage = settings.cutting.stepoverPercentage * tool.diameter / roughTool.diameter
        if leavesFloor {
            roughSettings.targetDepth = fullDepth - allowance
        }

        let roughOperation = compensatingForWiderTool(operation,
                                                      toolRadius: tool.diameter / 2.0,
                                                      widerRadius: roughTool.diameter / 2.0)

        guard var result = try buildPlainToolpath(for: contour,
                                                  tool: roughTool,
                                                  settings: roughSettings,
                                                  operation: roughOperation) else {
            return nil
        }

        // The roughing was planned with the wider stand-in; the output is for the real tool.
        result.operation = operation
        result.tool = tool
        result.settings = settings
        if case .pocket = operation {
            // The corners the real tool can't reach, not the stand-in's.
            result.restCorners = restCorners(in: contour.linearizedSegments, toolRadius: tool.diameter / 2.0)
        }

        guard settings.finishingPass else {
            return result
        }

        // MARK: Finishing

        // Real tool, true size, full depth, same layers as the roughing.
        var finishSettings = settings
        finishSettings.allowance = 0
        finishSettings.finishingPass = false
        finishSettings.retractPolicy = .safeZ
        finishSettings.targetDepth = fullDepth

        var finishPasses: [SC.ToolpathPass] = []

        switch operation {

            case .pocket(let direction, let pattern, let entry):

                // 1. The floor: one lap of the roughing pattern at full depth, in one pass.
                //    The pocket is already cleared down to `allowance` above that depth, so it
                //    cuts only the stock the roughing left. Plunge entry: a ramp or helix would
                //    spend its whole descent in air.
                var floorSettings = roughSettings
                floorSettings.targetDepth = fullDepth
                floorSettings.cutting.stepdown = fullDepth
                floorSettings.retractPolicy = .safeZ

                let floorOperation = compensatingForWiderTool(.pocket(direction: direction, pattern: pattern, entry: .plunge),
                                                              toolRadius: tool.diameter / 2.0,
                                                              widerRadius: roughTool.diameter / 2.0)

                if let floor = try buildPlainToolpath(for: contour,
                                                      tool: roughTool,
                                                      settings: floorSettings,
                                                      operation: floorOperation) {
                    // Rapid down through the cleared pocket to just above the roughing floor.
                    let clearZ = -(fullDepth - allowance) + 0.5
                    finishPasses += floor.passes.map { rapidingThroughClearedPocket($0, downTo: clearZ) }
                }

                // 2. The walls: islands first, then the pocket's own wall, each one lap per
                //    layer with the real tool. The entry is the pocket's own, except that a
                //    helix has no place on a wall, so it becomes a ramp at the same angle.
                let wallEntry: SC.EntryStrategy
                switch entry {
                    case .plunge, .fromOpenEnd:
                        wallEntry = .plunge
                    case .ramp(let angleDegrees):
                        wallEntry = .ramp(angleDegrees: angleDegrees)
                    case .helix(let angleDegrees):
                        wallEntry = .ramp(angleDegrees: angleDegrees)
                }

                for island in contour.islands {
                    let islandWall = SC.MachiningOperation.contour(side: .outside,
                                                                   direction: direction,
                                                                   entry: wallEntry,
                                                                   leadIn: nil,
                                                                   leadOut: nil,
                                                                   tabs: [])
                    let islandContour = SC.Contour(entities: island.entities, isClosed: island.isClosed)
                    if let wall = try buildPlainToolpath(for: islandContour,
                                                         tool: tool,
                                                         settings: finishSettings,
                                                         operation: islandWall) {
                        finishPasses += wall.passes
                    }
                }

                let pocketWall = SC.MachiningOperation.contour(side: .inside,
                                                               direction: direction,
                                                               entry: wallEntry,
                                                               leadIn: nil,
                                                               leadOut: nil,
                                                               tabs: [])
                let boundary = SC.Contour(entities: contour.entities, isClosed: true)
                if let wall = try buildPlainToolpath(for: boundary,
                                                     tool: tool,
                                                     settings: finishSettings,
                                                     operation: pocketWall) {
                    finishPasses += wall.passes
                }

            case .contour:
                // The same contour again at its true size, so its entry, lead-in/out and
                // holding tabs apply to the finishing too (the tabs must stay).
                if let finished = try buildPlainToolpath(for: contour,
                                                         tool: tool,
                                                         settings: finishSettings,
                                                         operation: operation) {
                    finishPasses += finished.passes
                }

            default:
                break
        }

        var index = result.passes.count
        for pass in finishPasses {
            result.passes.append(SC.ToolpathPass(passIndex: index, depthZ: pass.depthZ, waypoints: pass.waypoints))
            index += 1
        }
        return result
    }

    // MARK: - Helpers

    /// `operation` as it has to be handed to a wider stand-in tool so it still means the same
    /// thing in mm: a trochoidal pocket's loop pitch is a fraction of the tool radius.
    private func compensatingForWiderTool(_ operation: SC.MachiningOperation,
                                          toolRadius: Double,
                                          widerRadius: Double) -> SC.MachiningOperation {
        guard widerRadius > 1e-9,
              case .pocket(let direction, let pattern, let entry) = operation,
              case .trochoidal(let trochoidal) = pattern else {
            return operation
        }
        let scaled = SC.TrochoidalSettings(radialEngagement: trochoidal.radialEngagement * toolRadius / widerRadius,
                                           loopRadius: trochoidal.loopRadius)
        return .pocket(direction: direction, pattern: .trochoidal(settings: scaled), entry: entry)
    }

    /// A floor-finishing pass starts every plunge at safe Z, but everything above `clearZ` is
    /// already cut away: insert a rapid down to `clearZ` so only the last stretch is plunged
    /// at the plunge feed.
    private func rapidingThroughClearedPocket(_ pass: SC.ToolpathPass, downTo clearZ: Double) -> SC.ToolpathPass {
        var waypoints = pass.waypoints
        var i = 1
        while i < waypoints.count {
            let previous = waypoints[i - 1]
            let current = waypoints[i]
            let isPlunge = current.motion == .linear
                && previous.motion == .rapid
                && abs(previous.position.x - current.position.x) < 1e-9
                && abs(previous.position.y - current.position.y) < 1e-9
                && previous.position.z > clearZ + 1e-9
                && current.position.z < clearZ - 1e-9
            if isPlunge {
                waypoints.insert(SC.Waypoint(position: SIMD3(current.position.x, current.position.y, clearZ),
                                             motion: .rapid,
                                             feedRate: previous.feedRate),
                                 at: i)
                i += 1
            }
            i += 1
        }
        return SC.ToolpathPass(passIndex: pass.passIndex, depthZ: pass.depthZ, waypoints: waypoints)
    }
}
