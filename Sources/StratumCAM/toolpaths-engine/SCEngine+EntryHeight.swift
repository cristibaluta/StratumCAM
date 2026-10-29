//
//  SCEngine+EntryHeight.swift
//  StratumCAM
//
//  Implements `SC.MachineSettings.entryZ` for every operation at once.
//

import Foundation

extension SCEngine {

    /// Inserts the stop at `settings.entryZ` between the rapid at safe Z and the move down.
    ///
    /// Wherever a pass has a rapid at safe Z followed by a move straight down at the same XY, the
    /// tool now rapids to `entryZ` first and feeds from there:
    /// - a feed down (plunge) just starts from `entryZ` instead of from safe Z;
    /// - a rapid down to the top of the stock (the start of a ramp or helix on the first pass)
    ///   becomes a feed at the plunge rate from `entryZ`;
    /// - a rapid down into an already cut floor (later passes of a ramp or helix) stays a rapid.
    /// Layers already linked at a lower height by the retract policy don't start at safe Z and
    /// are left alone.
    func applyEntryHeight(to toolpath: SC.OutputToolpath) -> SC.OutputToolpath {
        let settings = toolpath.settings
        guard let entryZ = settings.entryZ, entryZ >= 0, entryZ < settings.safeZ - 1e-9 else {
            return toolpath
        }

        var result = toolpath
        result.passes = toolpath.passes.map { pass in
            var waypoints: [SC.Waypoint] = []
            waypoints.reserveCapacity(pass.waypoints.count + 2)

            for (index, next) in pass.waypoints.enumerated() {
                guard index > 0 else {
                    waypoints.append(next)
                    continue
                }
                let previous = pass.waypoints[index - 1]
                let isStraightDown = previous.motion == .rapid
                    && abs(previous.position.z - settings.safeZ) < 1e-9
                    && abs(previous.position.x - next.position.x) < 1e-9
                    && abs(previous.position.y - next.position.y) < 1e-9
                    && next.position.z < entryZ - 1e-9

                let isFeedDown = next.motion == .linear
                let isRapidToStockTop = next.motion == .rapid && next.position.z >= -1e-9

                guard isStraightDown, isFeedDown || isRapidToStockTop else {
                    waypoints.append(next)
                    continue
                }

                waypoints.append(SC.Waypoint(position: SIMD3(next.position.x, next.position.y, entryZ),
                                             motion: .rapid,
                                             feedRate: previous.feedRate))
                var feedDown = next
                if isRapidToStockTop {
                    feedDown.motion = .linear
                    feedDown.feedRate = settings.cutting.plungeRate
                }
                waypoints.append(feedDown)
            }
            return SC.ToolpathPass(passIndex: pass.passIndex, depthZ: pass.depthZ, waypoints: waypoints)
        }
        return result
    }
}
