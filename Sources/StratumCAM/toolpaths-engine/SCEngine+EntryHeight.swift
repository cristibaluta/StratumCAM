//
//  SCEngine+EntryHeight.swift
//  StratumCAM
//
//  Implements the plunge part of `SC.MachineSettings.rampStartZ` for every operation at once.
//  (Ramps and helixes read `settings.firstPassStartZ` where they are built.)
//

import Foundation

extension SCEngine {

    /// Inserts the stop at `settings.rampStartZ` between the rapid at safe Z and a plunge.
    ///
    /// Wherever a pass has a rapid at safe Z followed by a feed straight down at the same XY, the
    /// tool now rapids to `rampStartZ` first and feeds down from there instead of from safe Z.
    /// Rapids down (the start of a ramp or helix: to `firstPassStartZ` on the first pass, into
    /// an already cut floor on later ones) are left alone, since the ramp or helix itself
    /// starts at that height. Layers already linked at a lower height by the retract policy
    /// don't start at safe Z and are left alone too.
    func applyEntryHeight(to toolpath: SC.OutputToolpath) -> SC.OutputToolpath {
        let settings = toolpath.settings
        guard let startZ = settings.rampStartZ, startZ > 0, startZ < settings.safeZ - 1e-9 else {
            return toolpath
        }

        var result = toolpath
        result.passes = toolpath.passes.map { pass in
            var waypoints: [SC.Waypoint] = []
            waypoints.reserveCapacity(pass.waypoints.count + 2)

            for (index, next) in pass.waypoints.enumerated() {
                if index > 0 {
                    let previous = pass.waypoints[index - 1]
                    let isPlungeFromSafeZ = previous.motion == .rapid
                        && abs(previous.position.z - settings.safeZ) < 1e-9
                        && abs(previous.position.x - next.position.x) < 1e-9
                        && abs(previous.position.y - next.position.y) < 1e-9
                        && next.motion == .linear
                        && next.position.z < startZ - 1e-9
                    if isPlungeFromSafeZ {
                        waypoints.append(SC.Waypoint(position: SIMD3(next.position.x, next.position.y, startZ),
                                                     motion: .rapid,
                                                     feedRate: previous.feedRate))
                    }
                }
                waypoints.append(next)
            }
            return SC.ToolpathPass(passIndex: pass.passIndex, depthZ: pass.depthZ, waypoints: waypoints)
        }
        return result
    }
}
