//
//  ChamferParams.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public struct ChamferParams: Sendable, Equatable {
        /// Horizontal width of the bevel measured from the drawn edge (mm).
        /// Used together with the tool's `vAngle` to derive plunge depth when `depth` is nil.
        public var width: Double

        /// Explicit plunge depth override (mm, positive = distance below the top surface).
        /// When nil, depth is computed from `width` and the tool's V-bit included angle.
        public var depth: Double?

        /// Which side of the contour the bevel sits on -- same semantics as the `Side`
        /// used for contour cuts (`.outside` breaks an outer edge, `.inside` breaks a hole/pocket rim).
        public var side: CutSide

        /// Milling direction around the contour.
        public var direction: CutDirection

        public init(width: Double, depth: Double? = nil, side: CutSide = .outside, direction: CutDirection = .climb) {
            self.width = width
            self.depth = depth
            self.side = side
            self.direction = direction
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
        let halfAngleRad = (vAngle / 2.0).degreesToRadians
        return -(width / tan(halfAngleRad))
    }
}
