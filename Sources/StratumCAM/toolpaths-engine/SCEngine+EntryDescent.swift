//
//  SCEngine+EntryDescent.swift
//  StratumCAM
//
//  A ramp or helix on every pass after the first starts from the depth the pass before it
//  reached. The entry builders get the tool there with a RAPID straight down from safe Z
//  (`G00 X.. Y.. Z-0.150`). That is a rapid into material: the spot is normally already
//  cut, but nothing here guarantees it, and a rapid does not stop for anything.
//  This step turns that move into a feed move.
//

import Foundation

extension SCEngine {

    /// Replaces every rapid that goes straight down into the material with a feed move.
    ///
    /// The tool still rapids through the air: down to the entry height (`settings.firstPassStartZ`,
    /// where the first pass's entry starts, `startOffset` above `startZ`), then feeds the rest of
    /// the way at the plunge rate. Like `applyEntryHeight`, it runs on the finished passes of
    /// every operation at once, so each place that builds a ramp or helix entry gets it.
    ///
    /// A move is changed only if it:
    ///   - is a rapid, at the same XY as the waypoint before it (a pure descent), and
    ///   - ends below the entry height, i.e. inside the material, and
    ///   - belongs to an operation with ramp / helix entries (contour, pocket, 3D pocket,
    ///     slotting, counterbore). Drilling, boring and thread milling rapid down into a hole
    ///     that is already open, which is a different thing, and are left alone.
    /// Rapids that go up, or down only to the entry height in the air, are never touched.
    func applyEntryDescent(to toolpath: SC.OutputToolpath) -> SC.OutputToolpath {

        switch toolpath.operation {
            case .contour, .pocket, .pocket3D, .slotting, .counterbore:
                break
            default:
                return toolpath
        }

        let settings = toolpath.settings
        let entryZ = settings.firstPassStartZ
        let tolerance = 1e-9

        var result = toolpath
        result.passes = toolpath.passes.map { pass in
            var waypoints: [SC.Waypoint] = []
            waypoints.reserveCapacity(pass.waypoints.count + 2)

            for (index, waypoint) in pass.waypoints.enumerated() {
                guard index > 0 else {
                    waypoints.append(waypoint)
                    continue
                }
                let previous = pass.waypoints[index - 1]
                let isRapidIntoMaterial = waypoint.motion == .rapid
                    && abs(previous.position.x - waypoint.position.x) < tolerance
                    && abs(previous.position.y - waypoint.position.y) < tolerance
                    && waypoint.position.z < previous.position.z - tolerance
                    && waypoint.position.z < entryZ - tolerance

                guard isRapidIntoMaterial else {
                    waypoints.append(waypoint)
                    continue
                }

                // Through the air above the entry height: still a rapid.
                if previous.position.z > entryZ + tolerance {
                    waypoints.append(SC.Waypoint(position: SIMD3(waypoint.position.x, waypoint.position.y, entryZ),
                                                 motion: .rapid,
                                                 feedRate: waypoint.feedRate))
                }
                // From there down into the material: a normal feed move.
                waypoints.append(SC.Waypoint(position: waypoint.position,
                                             motion: .linear,
                                             feedRate: settings.cutting.plungeRate))
            }
            return SC.ToolpathPass(passIndex: pass.passIndex, depthZ: pass.depthZ, waypoints: waypoints)
        }
        return result
    }
}
