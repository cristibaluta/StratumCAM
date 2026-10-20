//
//  SCEngine+RetractPolicy.swift
//  StratumCAM
//
//  Shared implementation of `SC.MachineSettings.retractPolicy` for every operation that
//  cuts several Z layers (pocket, counterbore, slotting, contour).
//

import Foundation
import CoreGraphics

extension SCEngine {

    /// Replaces the full retract / re-approach at safe Z between two consecutive layers with
    /// the move `settings.retractPolicy` asks for.
    ///
    /// Expects every layer to start with a rapid at safe Z and end with a rapid back to safe
    /// Z, which is what the entry builders produce; a layer that doesn't look like that is
    /// left untouched. A gap between two layers also keeps the full retract when
    /// `canLink(endOfLayer, startOfNextLayer)` says the straight XY move between them isn't
    /// known to be safe. The last layer always retracts fully.
    ///
    /// - Parameter canLink: whether the tool may travel in a straight line between the two
    ///   XY points at a reduced height (i.e. over already-cleared material only).
    func applyRetractPolicy(to passes: inout [SC.ToolpathPass],
                            settings: SC.MachineSettings,
                            canLink: (CGPoint, CGPoint) -> Bool) {

        guard settings.retractPolicy != .safeZ, passes.count > 1 else {
            return
        }

        for i in 0..<(passes.count - 1) {
            var current = passes[i].waypoints
            var next = passes[i + 1].waypoints

            guard current.count >= 2, let nextStart = next.first, let last = current.last,
                  last.motion == .rapid, nextStart.motion == .rapid,
                  abs(last.position.z - settings.safeZ) < 1e-9,
                  abs(nextStart.position.z - settings.safeZ) < 1e-9 else {
                continue
            }

            let cutEnd = current[current.count - 2].position
            let from = CGPoint(x: cutEnd.x, y: cutEnd.y)
            let to = CGPoint(x: nextStart.position.x, y: nextStart.position.y)
            guard canLink(from, to) else {
                continue
            }

            let hoverZ: Double
            switch settings.retractPolicy {
                case .safeZ:
                    continue
                case .clearance:
                    hoverZ = min(cutEnd.z + settings.retractZ, settings.safeZ)
                case .none:
                    hoverZ = cutEnd.z
            }

            if hoverZ == cutEnd.z {
                current.removeLast()
            } else {
                current[current.count - 1] = SC.Waypoint(position: SIMD3(cutEnd.x, cutEnd.y, hoverZ),
                                                         motion: .rapid,
                                                         feedRate: last.feedRate)
            }
            next[0] = SC.Waypoint(position: SIMD3(nextStart.position.x, nextStart.position.y, hoverZ),
                                  motion: .rapid,
                                  feedRate: nextStart.feedRate)

            passes[i] = SC.ToolpathPass(passIndex: passes[i].passIndex, depthZ: passes[i].depthZ, waypoints: current)
            passes[i + 1] = SC.ToolpathPass(passIndex: passes[i + 1].passIndex, depthZ: passes[i + 1].depthZ, waypoints: next)
        }
    }

    /// Convenience for pocket-like operations: the link is allowed when the straight move
    /// between the two points stays inside the closed `region` (the area the tool centre has
    /// already cleared).
    func applyRetractPolicy(to passes: inout [SC.ToolpathPass],
                            settings: SC.MachineSettings,
                            within region: [SC.Segment]) {
        guard !region.isEmpty else {
            return
        }
        applyRetractPolicy(to: &passes, settings: settings) { from, to in
            linkStaysInside(from: from, to: to, wallRing: region)
        }
    }
}
