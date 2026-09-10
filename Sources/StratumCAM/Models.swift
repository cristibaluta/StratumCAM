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

    // MARK: - 1. Geometry & DXF Chaining

    public enum Segment: Sendable, Equatable {
        case line(start: CGPoint, end: CGPoint)
        case arc(center: CGPoint, radius: Double, startAngle: Double, endAngle: Double, isCCW: Bool)

        public var startPoint: CGPoint {
            switch self {
            case .line(let start, _): return start
            case .arc(let center, let radius, let startAngle, _, _):
                return CGPoint(x: center.x + radius * cos(startAngle), y: center.y + radius * sin(startAngle))
            }
        }

        public var endPoint: CGPoint {
            switch self {
            case .line(_, let end): return end
            case .arc(let center, let radius, _, let endAngle, _):
                return CGPoint(x: center.x + radius * cos(endAngle), y: center.y + radius * sin(endAngle))
            }
        }
    }

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

    // MARK: - 2. Tooling Configuration

    public enum ToolType: String, Sendable, Codable, Equatable {
        case flatEndMill
        case ballEndMill
        case vBit
        case drill
    }

    public struct ToolParams: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var type: ToolType
        public var diameter: Double         // Tool diameter (mm/in)
        public var stepdown: Double         // Max depth per Z-pass
        public var stepoverPercentage: Double // 0.1 to 0.95 (10% to 95% of tool diameter)
        public var vAngle: Double?          // Included angle in degrees for V-bits (e.g., 60.0, 90.0)
        public var fluteLength: Double      // Total cutting edge length (allows deep Z adaptive passes)
        public var maxOptimalLoad: Double   // Maximum radial stepover allowance for adaptive motion (mm)

        public init(
            id: UUID = UUID(),
            name: String = "1/4\" Flat End Mill",
            type: ToolType = .flatEndMill,
            diameter: Double = 6.35,
            stepdown: Double = 1.5,
            stepoverPercentage: Double = 0.4,
            vAngle: Double? = nil,
            fluteLength: Double = 12,
            maxOptimalLoad: Double = 0.0
        ) {
            self.id = id
            self.name = name
            self.type = type
            self.diameter = diameter
            self.stepdown = stepdown
            self.stepoverPercentage = stepoverPercentage
            self.vAngle = vAngle
            self.fluteLength = fluteLength
            self.maxOptimalLoad = maxOptimalLoad
        }
    }

    // MARK: - 3. Machine & Stock Setup

    public struct Stock: Sendable, Equatable {
        public var width: Double            // X size
        public var height: Double           // Y size
        public var thickness: Double        // Z size
        public var origin: SIMD3<Double>    // Work coordinate offset (WCS G54 origin)

        public init(width: Double, height: Double, thickness: Double, origin: SIMD3<Double> = .zero) {
            self.width = width
            self.height = height
            self.thickness = thickness
            self.origin = origin
        }
    }

    public struct MachineSettings: Sendable, Equatable {
        public var feedRate: Double         // XY cutting feed rate (mm/min)
        public var plungeRate: Double       // Z plunge feed rate (mm/min)
        public var spindleSpeed: Double     // RPM
        public var safeZ: Double            // Rapid clearance plane above stock
        public var retractZ: Double         // Short lift clearance between close cuts
        public var targetDepth: Double      // Total depth of cut (positive depth into stock)

        public init(
            feedRate: Double = 1200.0,
            plungeRate: Double = 300.0,
            spindleSpeed: Double = 12000.0,
            safeZ: Double = 5.0,
            retractZ: Double = 1.0,
            targetDepth: Double = 3.0
        ) {
            self.feedRate = feedRate
            self.plungeRate = plungeRate
            self.spindleSpeed = spindleSpeed
            self.safeZ = safeZ
            self.retractZ = retractZ
            self.targetDepth = targetDepth
        }
    }

    // MARK: - 4. Machining Operations & Strategies

    public enum Side: String, Sendable, Codable, Equatable {
        case inside
        case outside
        case onContour
    }

    public enum CutDirection: String, Sendable, Codable, Equatable {
        case climb                          // Standard for CNC mills
        case conventional
    }

    public struct HoldingTab: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var positionRatio: Double    // 0.0 to 1.0 parametric distance along contour
        public var width: Double            // Length along toolpath (mm)
        public var height: Double           // Remaining stock height for tab (mm)

        public init(id: UUID = UUID(), positionRatio: Double, width: Double = 6.0, height: Double = 1.5) {
            self.id = id
            self.positionRatio = positionRatio
            self.width = width
            self.height = height
        }
    }

    public enum EntryStrategy: Sendable, Equatable {
        /// Direct vertical plunge into pre-drilled holes or soft material.
        case plunge

        /// Zig-zag back and forth at a shallow angle to reach pass depth.
        case ramp(angleDegrees: Double)

        /// Spiral down into the material in a circular motion (ideal for pockets/adaptive).
        case helix(radius: Double, rampAngleDegrees: Double)
    }

    public struct LeadInOut: Sendable, Equatable {
        public enum Style: Sendable, Equatable {
            case linear(length: Double)
            case arc(radius: Double, sweepAngleDegrees: Double)
        }

        public var style: Style
        public var feedRate: Double

        public init(style: Style, feedRate: Double) {
            self.style = style
            self.feedRate = feedRate
        }
    }

    public enum AdaptiveType: String, Sendable, Codable, Equatable {
        case clearing2D           // Adaptive pocket / dynamic roughing
        case adaptiveContour      // High-speed profile adaptive clearing
    }

    public enum PocketType: String, Sendable, Codable, Equatable {
        case offsetPattern               // Concentric inner-to-outer shapes
        case raster                      // Parallel scanlines
    }

    public enum CAMStrategy: Sendable, Equatable {
        case engrave

        case profile(
            side: Side,
            direction: CutDirection,
            entry: EntryStrategy,           // 💡 Ramping/Plunge strategy
            leadIn: LeadInOut?,             // Smooth tool entry onto profile wall
            leadOut: LeadInOut?,            // Smooth tool departure
            tabs: [HoldingTab]
        )

        case pocket(
            direction: CutDirection,
            pocketType: PocketType,
            entry: EntryStrategy            // 💡 Ramp or Helical entry into solid pocket stock
        )

        case drilling(peckDepth: Double?)

        case adaptiveClearing(type: AdaptiveType,
                              direction: CutDirection,
                              optimalLoad: Double,      // Target radial engagement / stepover distance (mm)
                              entry: EntryStrategy      // Usually .helix
        )
    }

    // MARK: - 5. Toolpath Waypoints & Output Generation

    public enum MotionType: Sendable, Equatable {
        case rapid                          // G00
        case linear                         // G01
        case arcCW(center: CGPoint)         // G02
        case arcCCW(center: CGPoint)        // G03
    }

    public struct Waypoint: Sendable, Equatable {
        public var position: SIMD3<Double>
        public var motion: MotionType
        public var feedRate: Double

        public init(position: SIMD3<Double>, motion: MotionType, feedRate: Double) {
            self.position = position
            self.motion = motion
            self.feedRate = feedRate
        }
    }

    public struct ToolpathPass: Sendable, Equatable {
        public var passIndex: Int
        public var depthZ: Double
        public var waypoints: [Waypoint]

        public init(passIndex: Int, depthZ: Double, waypoints: [Waypoint]) {
            self.passIndex = passIndex
            self.depthZ = depthZ
            self.waypoints = waypoints
        }
    }

    public struct OutputToolpath: Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var strategy: CAMStrategy
        public var tool: ToolParams
        public var settings: MachineSettings
        public var passes: [ToolpathPass]

        public init(
            id: UUID = UUID(),
            name: String = "Toolpath Operation",
            strategy: CAMStrategy,
            tool: ToolParams,
            settings: MachineSettings,
            passes: [ToolpathPass]
        ) {
            self.id = id
            self.name = name
            self.strategy = strategy
            self.tool = tool
            self.settings = settings
            self.passes = passes
        }
    }
}
