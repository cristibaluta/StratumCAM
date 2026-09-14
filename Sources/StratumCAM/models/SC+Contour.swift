//
//  Contour.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation
import SwiftDXF

extension SC {

    public struct Contour: Sendable {
        
        public struct Chained: Sendable {
            public var entity: DXF.Entity
            public var reversed: Bool

            // The inits are needed because the app using the lib is not able to init otherwise
            public init(entity: DXF.Entity, reversed: Bool) {
                self.entity = entity
                self.reversed = reversed
            }
        }

        public var entities: [Chained]
        public var isClosed: Bool

        public init(entities: [Chained], isClosed: Bool) {
            self.entities = entities
            self.isClosed = isClosed
        }
    }
}

extension SC.Contour {
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
    var drillPoint: CGPoint? {
        guard self.entities.count == 1 else {
            return nil
        }
        switch self.entities[0].entity {
            case let .point(at, _, _):
                return at.cgPoint

            case let .circle(center, _, _, _):
                return isClosed ? center.cgPoint : nil

            default:
                return nil
        }
    }
}
