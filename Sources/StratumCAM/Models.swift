//
//  Segment.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 10.09.2026.
//

import Foundation
import CoreGraphics
import simd
import SwiftDXF

public enum SC {

    public struct Contour {
        public struct Chained: Sendable {
            public var entity: DXF.Entity
            public var reversed: Bool   // true if this entity is walked from its "b" endpoint to its "a" endpoint

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

    /// Standardized primitives understood by standard CNC controllers
    enum Segment: Sendable {
        case line(start: CGPoint, end: CGPoint)
        /// Sweep arc in XY plane. Angles in radians CCW from positive X-axis.
        case arc(center: CGPoint, radius: Double, startAngle: Double, endAngle: Double, isCCW: Bool)
    }

    // MARK: - Settings & Metadata

    public struct ToolParams: Sendable {
        public var id: UUID
        public var diameter: Double
        public var stepdown: Double // Max Z cut depth per pass

        public init(id: UUID = UUID(), diameter: Double, stepdown: Double) {
            self.id = id
            self.diameter = diameter
            self.stepdown = stepdown
        }
    }

    public struct MachineSettings: Sendable {
        public var feedRate: Double   // XY cut speed
        public var plungeRate: Double // Z depth speed
        public var targetDepth: Double // Total cut depth (negative Z)
        public var safeZ: Double      // Retraction clearance height (positive Z)

        public init(feedRate: Double, plungeRate: Double, targetDepth: Double, safeZ: Double) {
            self.feedRate = feedRate
            self.plungeRate = plungeRate
            self.targetDepth = targetDepth
            self.safeZ = safeZ
        }
    }

    // MARK: - Output Toolpath Models

    public struct OutputToolpath: Sendable {
        public var sourceContourID: UUID
        public var passes: [ToolpathPass]
    }

    public struct ToolpathPass: Sendable {
        public var depthZ: Double
        public var waypoints: [Waypoint]
    }

    public struct Waypoint: Sendable {
        public var position: SIMD3<Double> // X, Y, Z
        public var motion: MotionType
        public var feedRate: Double
    }

    public enum MotionType: Sendable {
        case rapid
        case linear
        case arcCW(center: CGPoint)
        case arcCCW(center: CGPoint)
    }
}
