//
//  SCEngine+Drilling.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import CoreGraphics
import SwiftDXF

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
}
