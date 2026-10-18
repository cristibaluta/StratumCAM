//
//  SC+Geometry.swift
//  StratumCAM
//
//  Library-native input geometry. Replaces `SC.Geometry` so the core has no third-party
//  dependency; the `StratumCAMDXF` target converts DXF entities to this type.
//

import Foundation
import simd

extension SC {

    /// A 2D drawing primitive. Only machinable primitives are modelled (no text,
    /// dimensions, layers or colors).
    public enum Geometry: Sendable, Equatable {

        /// A polyline vertex. `bulge` is `tan(θ/4)` of the arc to the next vertex
        /// (`0` for a straight segment, positive = CCW).
        public struct Vertex: Sendable, Equatable {
            public var point: SIMD2<Double>
            public var bulge: Double

            public init(_ point: SIMD2<Double>, bulge: Double = 0) {
                self.point = point
                self.bulge = bulge
            }
        }

        case line(a: SIMD2<Double>, b: SIMD2<Double>)
        case circle(center: SIMD2<Double>, radius: Double)
        /// Circular arc. Angles are absolute, in degrees; the arc sweeps CCW from start to end.
        case arc(center: SIMD2<Double>, radius: Double, startDeg: Double, endDeg: Double)
        /// Ellipse / elliptical arc. `majorAxis` is the major-axis endpoint relative to `center`,
        /// `ratio` is minor/major, `startParam`/`endParam` are parametric bounds in radians
        /// (`0...2π` for a full ellipse).
        case ellipse(center: SIMD2<Double>, majorAxis: SIMD2<Double>, ratio: Double, startParam: Double, endParam: Double)
        /// A marker with no extent, e.g. a drill location.
        case point(at: SIMD2<Double>)
        case polyline(vertices: [Vertex], closed: Bool)
    }
}

extension SIMD2 where Scalar == Double {

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}
