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

    /// Builds a basic drill cycle: rapid to the hole's XY at Safe Z, plunge straight to
    /// target depth, retract to Safe Z. One `ToolpathPass`, since a plain drill doesn't
    /// step down in the sense profile/pocket passes do -- it's a single continuous plunge.
    ///
    /// Peck drilling (`peckDepth != nil`) isn't implemented yet (see Step 1.3) --
    /// returning `nil` here rather than silently drilling a plain hole when pecking was
    /// actually requested, since that's a real behavioral difference a caller is relying on.
    func buildDrillingToolpath(for contour: SC.Contour,
                               tool: SC.ToolParams,
                               settings: SC.MachineSettings,
                               peckDepth: Double?,
                               strategy: SC.Strategy) -> SC.OutputToolpath? {

        guard let point = drillPoint(for: contour) else {
            return nil
        }

        guard peckDepth == nil else {
            // TODO(Step 1.3): peck-cycle drilling.
            return nil
        }

        let z = -abs(settings.targetDepth)

        let waypoints: [SC.Waypoint] = [
            SC.Waypoint(position: SIMD3(point.x, point.y, settings.safeZ), motion: .rapid, feedRate: settings.feedRate),
            SC.Waypoint(position: SIMD3(point.x, point.y, z), motion: .linear, feedRate: settings.plungeRate),
            SC.Waypoint(position: SIMD3(point.x, point.y, settings.safeZ), motion: .rapid, feedRate: settings.feedRate)
        ]

        let pass = SC.ToolpathPass(passIndex: 0, depthZ: z, waypoints: waypoints)
        return SC.OutputToolpath(strategy: strategy, tool: tool, settings: settings, passes: [pass])
    }
}
