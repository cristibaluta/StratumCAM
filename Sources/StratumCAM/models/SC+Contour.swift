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
    /// circle) returns `nil` here -- it isn't an explicit point/circle marker. `.drilling`
    /// doesn't stop at `nil`, though: it falls back to `closedShapeCenter` below, so a
    /// closed contour of any shape is still drillable at its center; this property alone
    /// stays narrow because `.boring`/`.counterbore`/`.threadMilling` reuse it too, and a
    /// bounding-box center isn't the right fallback for cutting to an exact diameter.
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

    /// The axis-aligned bounding-box center of a closed contour's geometry -- "the
    /// middle of whatever shape this is," regardless of what that shape is. `.drilling`
    /// falls back to this (see `SCEngine.buildDrillingToolpath`) when a contour isn't a
    /// single point or closed circle, so any closed boundary -- a square, an odd
    /// polygon, a rounded rectangle -- is still drillable at its center. That's useful
    /// for e.g. pre-drilling a stress-relief hole in the middle of a pocket boundary
    /// before running an adaptive-clearing pass over it, without having to separately
    /// mark a point or circle at the same spot.
    ///
    /// This is a bounding-box center, not a true polygon centroid: exact for a circle or
    /// anything symmetric about its bounding box (square, rectangle, rounded rectangle),
    /// only an approximation for an irregular or concave shape, where it can land
    /// outside the boundary entirely (e.g. an L- or C-shaped pocket). That's an
    /// acceptable trade for a relief pre-drill; it isn't a substitute for a real
    /// centroid if a caller ever needs the point guaranteed inside the boundary.
    ///
    /// `nil` for an open contour (no well-defined "middle") or one with no measurable
    /// geometry.
    var closedShapeCenter: CGPoint? {
        guard isClosed else {
            return nil
        }

        let box = linearizedSegments.boundingBox
        guard box.minX.isFinite, box.maxX.isFinite, box.minY.isFinite, box.maxY.isFinite else {
            return nil
        }

        return CGPoint(x: (box.minX + box.maxX) / 2, y: (box.minY + box.maxY) / 2)
    }
}
