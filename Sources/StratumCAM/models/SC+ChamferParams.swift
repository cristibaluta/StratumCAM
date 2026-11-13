//
//  ChamferParams.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    /// Which end of the bevel the selected contour marks.
    public enum ChamferEdge: String, Sendable, Codable, Equatable, CaseIterable {

        /// The contour is the edge on the top surface, at `edgeZ` (default 0). The bevel is cut from
        /// `edgeZ` down by its depth; the tool tip finishes on the contour, at the bevel's bottom.
        case top

        /// The contour is the bevel's LOWER edge -- typically the part's wall. The tool tip finishes
        /// on the contour and the bevel runs up and away from it, to the side opposite the tool.
        case bottom
    }

    public struct ChamferParams: Sendable, Equatable {
        /// Horizontal width of the bevel (mm), measured from the selected edge.
        /// Used together with the tool's `vAngle` to derive the bevel's depth when `depth` is nil.
        /// The two are tied by the tool's angle: `depth = width / tan(vAngle / 2)`, so they are
        /// equal only for a 90 degree V-bit.
        public var width: Double

        /// Explicit bevel depth override (mm, positive = vertical height of the bevel).
        /// When nil, depth is computed from `width` and the tool's V-bit included angle.
        public var depth: Double?

        /// Which side of the contour the tool works on -- same semantics as the `Side`
        /// used for contour cuts (`.outside` breaks an outer edge, `.inside` breaks a hole/pocket rim).
        public var side: CutSide

        /// Milling direction around the contour.
        public var direction: CutDirection

        /// Whether the selected contour is the bevel's top or bottom edge.
        public var edge: ChamferEdge

        /// Z of the selected contour (mm, 0 = top of the stock, negative = below it).
        /// - `.top`: the bevel starts here and goes down by its depth (the tip finishes below
        ///   it by `depth`). Default 0.
        /// - `.bottom`: the bevel ENDS here: it is cut from `edgeZ + depth` (the top) down to
        ///   `edgeZ`. Default (nil) is `-depth`, which puts the top of the bevel on the stock's
        ///   top surface (Z = 0) -- the edge itself sits below the stock top.
        public var edgeZ: Double?

        /// Which part of the tool's angled flank makes the bevel: the height (mm, along the
        /// tool axis) above the tool tip at which the bevel's lowest point is cut. 0 uses the
        /// tip; a larger value cuts with the flank higher up, which spreads the wear and moves
        /// the tool center away from the contour by `tipOffset * tan(vAngle / 2)`
        /// (added to `tipWidth / 2`, the offset of a tool with a flat tip).
        /// `tipOffset + depth` must not exceed `ToolParams.flankHeight`.
        public var tipOffset: Double

        public init(width: Double,
                    depth: Double? = nil,
                    side: CutSide = .outside,
                    direction: CutDirection = .climb,
                    edge: ChamferEdge = .top,
                    edgeZ: Double? = nil,
                    tipOffset: Double = 0) {
            self.width = width
            self.depth = depth
            self.side = side
            self.direction = direction
            self.edge = edge
            self.edgeZ = edgeZ
            self.tipOffset = tipOffset
        }
    }
}

extension SC.ChamferParams {

    /// Resolves the bevel's vertical depth (as a NEGATIVE number, `-depth`) from this tool's V-bit
    /// included angle. Returns `nil` if the tool isn't a usable V-bit (wrong `type`, or missing/zero
    /// `vAngle`) and no explicit `depth` is given -- callers should treat that as a configuration
    /// error rather than fall back to a guessed depth.
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

    /// The bevel's horizontal width and vertical depth (both positive), tied by the tool's
    /// angle. `nil` when the tool isn't a V-bit with a usable `vAngle`.
    public func resolvedBevel(for tool: SC.ToolParams) -> (width: Double, depth: Double)? {
        guard tool.type == .vBit, let vAngle = tool.vAngle, vAngle > 0, vAngle < 180 else {
            return nil
        }
        let tanHalf = tan((vAngle / 2.0).degreesToRadians)
        if let depth {
            let height = abs(depth)
            return (width: height * tanHalf, depth: height)
        }
        return (width: abs(width), depth: abs(width) / tanHalf)
    }

    /// The Z of the bevel's lowest and highest points for a bevel of vertical `depth`.
    public func bevelZRange(depth: Double) -> (bottom: Double, top: Double) {
        switch edge {
            case .top:
                let top = edgeZ ?? 0
                return (bottom: top - depth, top: top)
            case .bottom:
                let bottom = edgeZ ?? -depth
                return (bottom: bottom, top: bottom + depth)
        }
    }

    /// The Z the selected contour sits at: the bevel's top for a `.top` edge, its bottom for a
    /// `.bottom` edge (so a bottom edge sits LOWER than the stock top). `nil` when the tool
    /// can't resolve a bevel. Useful for drawing the reference outline at the right height.
    public func contourZ(for tool: SC.ToolParams) -> Double? {
        guard let bevel = resolvedBevel(for: tool) else {
            return nil
        }
        let range = bevelZRange(depth: bevel.depth)
        return (edge == .top) ? range.top : range.bottom
    }

    /// Checks the tool can physically cut this bevel.
    ///
    /// - Throws: `SC.Error.toolIncompatible` for a tool that isn't a V-bit with an angle,
    ///   `SC.Error.invalidParameter` for a negative tip offset or a tip flat that isn't smaller
    ///   than the diameter, and `SC.Error.chamferExceedsToolReach` when
    ///   `tipOffset + depth` is taller than the tool's angled flank.
    public func validateReach(for tool: SC.ToolParams) throws {
        guard let bevel = resolvedBevel(for: tool), let flank = tool.flankHeight else {
            throw SC.Error.toolIncompatible
        }
        guard tool.tipWidth >= 0, tool.tipWidth < tool.diameter else {
            throw SC.Error.invalidParameter("tool.tipWidth")
        }
        guard tipOffset >= 0 else {
            throw SC.Error.invalidParameter("chamfer.params.tipOffset")
        }
        let required = tipOffset + bevel.depth
        guard required <= flank + 1e-9 else {
            throw SC.Error.chamferExceedsToolReach(required: required, available: flank)
        }
    }
}
