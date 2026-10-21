//
//  MotionType.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public struct OutputToolpath: Sendable, Identifiable {

        public var id: UUID
        public var name: String
        public var operation: MachiningOperation
        public var tool: ToolParams
        public var settings: MachineSettings
        public var passes: [ToolpathPass]
        /// Sharp corners this tool couldn't reach, for a follow-up pass with a smaller tool.
        public var restCorners: [RestCorner]

        public init(id: UUID = UUID(),
                    name: String = "Toolpath Operation",
                    operation: MachiningOperation,
                    tool: ToolParams,
                    settings: MachineSettings,
                    passes: [ToolpathPass],
                    restCorners: [RestCorner] = []) {

            self.id = id
            self.name = name
            self.operation = operation
            self.tool = tool
            self.settings = settings
            self.passes = passes
            self.restCorners = restCorners
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

    public enum MotionType: Sendable, Equatable {
        case rapid                          // G00
        case linear                         // G01
        case arcCW(center: CGPoint)         // G02
        case arcCCW(center: CGPoint)        // G03
    }

    /// Material left in a pocket corner because the tool radius is larger than the corner.
    public struct RestCorner: Sendable, Equatable {
        /// The sharp vertex on the true pocket wall.
        public var corner: CGPoint
        /// Unit direction of the wall arriving at the corner.
        public var tangentIn: CGPoint
        /// Unit direction of the wall leaving the corner.
        public var tangentOut: CGPoint
        /// Pocket interior angle at the corner, radians.
        public var interiorAngle: Double
        /// Radius of the tool that left this material.
        public var toolRadius: Double
        /// Closed contour of the leftover sliver: wall, wall, then the tool-circle arc.
        public var region: [Segment]

        public init(corner: CGPoint,
                    tangentIn: CGPoint,
                    tangentOut: CGPoint,
                    interiorAngle: Double,
                    toolRadius: Double,
                    region: [Segment]) {
            self.corner = corner
            self.tangentIn = tangentIn
            self.tangentOut = tangentOut
            self.interiorAngle = interiorAngle
            self.toolRadius = toolRadius
            self.region = region
        }
    }

}

extension SC.MotionType {

    var isArc: Bool {
        switch self {
            case .arcCW, .arcCCW: return true
            case .rapid, .linear: return false
        }
    }
}
