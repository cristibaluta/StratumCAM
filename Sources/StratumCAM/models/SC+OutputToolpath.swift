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

        public init(id: UUID = UUID(),
                    name: String = "Toolpath Operation",
                    operation: MachiningOperation,
                    tool: ToolParams,
                    settings: MachineSettings,
                    passes: [ToolpathPass]) {

            self.id = id
            self.name = name
            self.operation = operation
            self.tool = tool
            self.settings = settings
            self.passes = passes
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

}
