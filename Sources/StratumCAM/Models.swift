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

    /// Defines the toolpath strategy used to machine a feature.
    ///
    /// Each strategy represents a different machining operation and contains
    /// the parameters required to generate its corresponding toolpath.
    public enum CAMStrategy: Sendable, Equatable {

        /// Engraves geometry along curves, text, or other shallow features.
        ///
        /// Typically follows the selected geometry directly with the tool centerline
        /// positioned according to the engraving operation's tool compensation rules.
        case engrave

        /// Machines the outside or inside wall of a closed profile.
        ///
        /// Supports conventional or climb cutting, controlled tool entry and exit,
        /// and optional holding tabs for keeping the workpiece attached to stock.
        ///
        /// - Parameters:
        ///   - side: Determines whether the tool cuts on the inside or outside
        ///     of the selected profile.
        ///   - direction: Determines the cutting direction, such as climb or
        ///     conventional milling.
        ///   - entry: Defines how the tool enters the material, for example by
        ///     plunging or ramping.
        ///   - leadIn: Optional lead-in move used to smoothly engage the profile
        ///     rather than entering directly on the cutting wall.
        ///   - leadOut: Optional lead-out move used to smoothly leave the profile
        ///     before retracting.
        ///   - tabs: Holding tabs left in the profile to prevent the finished
        ///     part from moving or separating from the stock during machining.
        case profile(
            side: Side,
            direction: CutDirection,
            entry: EntryStrategy,
            leadIn: LeadInOut?,
            leadOut: LeadInOut?,
            tabs: [HoldingTab]
        )

        /// Removes material from inside a closed boundary to create a pocket.
        ///
        /// The toolpath progressively clears the interior area while maintaining
        /// the selected cutting direction and pocketing pattern.
        ///
        /// - Parameters:
        ///   - direction: Determines the cutting direction, such as climb or
        ///     conventional milling.
        ///   - pocketType: Defines the pocket-clearing pattern or geometry strategy.
        ///   - entry: Defines how the tool enters the pocket, such as a ramp or
        ///     helical entry. Helical entry is useful for reducing the impact of
        ///     plunging directly into solid material.
        case pocket(
            direction: CutDirection,
            pocketType: PocketType,
            entry: EntryStrategy
        )

        /// Drills one or more holes at the specified locations.
        ///
        /// Optionally uses peck drilling, where the tool repeatedly retracts
        /// partially from the hole to evacuate chips and reduce heat.
        ///
        /// - Parameter peckDepth: Maximum depth of each drilling peck.
        ///   A value of `nil` indicates a continuous drilling operation without
        ///   pecking.
        case drilling(peckDepth: Double?)

        /// Machines a beveled edge using a chamfering tool.
        ///
        /// The chamfer parameters determine the resulting bevel geometry,
        /// cutting depth, and other operation-specific settings.
        ///
        /// - Parameter params: Parameters describing the desired chamfer geometry
        ///   and machining behavior.
        case chamfer(params: ChamferParams)

        /// Dynamically clears large amounts of material while maintaining a
        /// controlled cutter engagement.
        ///
        /// Adaptive clearing continuously adjusts the toolpath to maintain a
        /// relatively constant radial tool engagement. This allows aggressive
        /// material removal while reducing sudden changes in cutting load.
        ///
        /// - Parameters:
        ///   - type: Defines the adaptive clearing pattern or behavior.
        ///   - direction: Determines the cutting direction, such as climb or
        ///     conventional milling.
        ///   - optimalLoad: Target radial tool engagement in millimeters. The
        ///     generated toolpath attempts to maintain approximately this amount
        ///     of cutter engagement where geometry permits.
        ///   - entry: Defines how the cutter enters the material. Helical entry
        ///     is commonly used for entering solid stock without a full-depth
        ///     vertical plunge.
        case adaptiveClearing(
            type: AdaptiveType,
            direction: CutDirection,
            optimalLoad: Double,
            entry: EntryStrategy
        )
    }

    // MARK: - Chamfering

    public struct ChamferParams: Sendable, Equatable {
        /// Horizontal width of the bevel measured from the drawn edge (mm).
        /// Used together with the tool's `vAngle` to derive plunge depth when `depth` is nil.
        public var width: Double

        /// Explicit plunge depth override (mm, positive = distance below the top surface).
        /// When nil, depth is computed from `width` and the tool's V-bit included angle.
        public var depth: Double?

        /// Which side of the contour the bevel sits on -- same semantics as the `Side`
        /// used for profile cuts (`.outside` breaks an outer edge, `.inside` breaks a hole/pocket rim).
        public var side: Side

        /// Milling direction around the contour.
        public var direction: CutDirection

        public init(width: Double, depth: Double? = nil, side: Side = .outside, direction: CutDirection = .climb) {
            self.width = width
            self.depth = depth
            self.side = side
            self.direction = direction
        }
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

extension SC.ChamferParams {

    /// Resolves the Z plunge depth for a chamfer pass from this tool's V-bit included angle.
    /// Returns `nil` if the tool isn't a usable V-bit (wrong `type`, or missing/zero `vAngle`) --
    /// callers should treat that as a configuration error rather than fall back to a guessed depth.
    public func resolvedDepth(for tool: SC.ToolParams) -> Double? {
        if let depth {
            return -abs(depth)
        }
        guard tool.type == .vBit, let vAngle = tool.vAngle, vAngle > 0 else {
            return nil
        }
        let halfAngleRad = (vAngle / 2.0) * .pi / 180.0
        return -(width / tan(halfAngleRad))
    }
}
