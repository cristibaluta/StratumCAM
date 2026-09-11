//
//  SCEngine+Drilling.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import CoreGraphics
import SwiftDXF
import simd

extension SCEngine {

    /// Extracts a single drill point (XY) from a contour, if the contour represents
    /// one. Two shapes are recognized as "drill here" markers:
    /// - A single `.point` entity -- the explicit case.
    /// - A single closed `.circle` entity -- common in DXF for marking hole centers,
    ///   since many CAD tools don't have a dedicated point primitive for this. `isClosed`
    ///   must be `true` so a circle used for other strategies (e.g. engraving a ring)
    ///   isn't silently reinterpreted as a hole.
    ///
    /// Any other contour shape (lines, arcs, polylines, multiple entities, an open
    /// circle) returns `nil` -- it isn't a drillable point, it's geometry for another
    /// strategy.
    func drillPoint(for contour: SC.Contour) -> CGPoint? {
        guard contour.entities.count == 1 else {
            return nil
        }

        switch contour.entities[0].entity {
            case let .point(at, _, _):
                return at.cgPoint

            case let .circle(center, _, _, _):
                guard contour.isClosed else {
                    return nil
                }
                return center.cgPoint

            default:
                return nil
        }
    }

    /// Builds a drill cycle: rapid to the hole's XY at Safe Z, then either a single
    /// straight plunge (`peckDepth == nil`) or a peck cycle (`peckDepth != nil`), ending
    /// with a retract to Safe Z. One `ToolpathPass` either way, since a drill cycle
    /// doesn't step down in the sense profile/pocket passes do -- pecking is internal
    /// motion within a single hole, not separate Z-passes over 2D geometry.
    func buildDrillingToolpath(for contour: SC.Contour,
                               tool: SC.ToolParams,
                               settings: SC.MachineSettings,
                               peckDepth: Double?,
                               strategy: SC.Strategy) -> SC.OutputToolpath? {

        guard let point = drillPoint(for: contour) else {
            return nil
        }

        let z = -abs(settings.targetDepth)

        let waypoints: [SC.Waypoint]
        if let peckDepth, peckDepth > 0 {
            waypoints = peckDrillingWaypoints(at: point, peckDepth: peckDepth, settings: settings)
        } else {
            waypoints = [
                SC.Waypoint(position: SIMD3(point.x, point.y, settings.safeZ), motion: .rapid, feedRate: settings.feedRate),
                SC.Waypoint(position: SIMD3(point.x, point.y, z), motion: .linear, feedRate: settings.plungeRate),
                SC.Waypoint(position: SIMD3(point.x, point.y, settings.safeZ), motion: .rapid, feedRate: settings.feedRate)
            ]
        }

        let pass = SC.ToolpathPass(passIndex: 0, depthZ: z, waypoints: waypoints)
        return SC.OutputToolpath(strategy: strategy, tool: tool, settings: settings, passes: [pass])
    }

    /// Builds the waypoints for a peck-drilling cycle at a single hole location.
    ///
    /// Reuses `calculateZPasses` to derive the peck depths -- it already does exactly
    /// what pecking needs: step down by a fixed increment (`peckDepth` here, in place of
    /// a tool's Z-stepdown) until `settings.targetDepth`, with the same rounding-safe
    /// handling so an evenly-divisible depth/peck pair doesn't gain a spurious extra peck.
    ///
    /// Each peck plunges (`.linear` at `plungeRate`) one increment deeper than the last,
    /// then retracts (`.rapid`) to clear chips. Between pecks that retract only goes to
    /// `settings.retractZ` -- a short clearance close to the hole -- rather than all the
    /// way back up to `settings.safeZ`, since climbing to full Safe Z after every peck
    /// would waste rapid travel on a deep hole. The final retract after the last peck
    /// does go all the way to `safeZ`, matching the plain (non-peck) drill cycle.
    func peckDrillingWaypoints(at point: CGPoint, peckDepth: Double, settings: SC.MachineSettings) -> [SC.Waypoint] {
        let peckDepths = calculateZPasses(targetDepth: settings.targetDepth, stepdown: peckDepth)

        var waypoints: [SC.Waypoint] = [
            SC.Waypoint(position: SIMD3(point.x, point.y, settings.safeZ), motion: .rapid, feedRate: settings.feedRate)
        ]

        for (index, depth) in peckDepths.enumerated() {
            waypoints.append(SC.Waypoint(position: SIMD3(point.x, point.y, depth), motion: .linear, feedRate: settings.plungeRate))

            let isLastPeck = index == peckDepths.count - 1
            let retractTo = isLastPeck ? settings.safeZ : settings.retractZ
            waypoints.append(SC.Waypoint(position: SIMD3(point.x, point.y, retractTo), motion: .rapid, feedRate: settings.feedRate))
        }

        return waypoints
    }
}
