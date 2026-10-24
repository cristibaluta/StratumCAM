//
//  EntryStrategy.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    /// Defines how the tool transitions from stock clearance Z-height down into solid material.
    public enum EntryStrategy: Sendable, Equatable {

        /// Direct vertical plunge into solid material or pre-drilled entry holes.
        ///
        /// - Real-World Impact: Drives the end mill straight down along the Z-axis into material.
        /// - Pros: Fastest entry method; minimal XY movement during entry.
        /// - Cons: Highest Z-axis cutting load; non-center-cutting end mills will burn or break; causes severe tip wear in hard materials.
        /// - Standard Use: Pre-drilled entry holes, soft materials (foams/plastics), or cutting off the edge of stock in open air.
        case plunge

        /// Zig-zag motion back and forth at a shallow incline angle down to cut depth.
        ///
        /// - Real-World Impact: Converts a high-load vertical plunge into a combination of XY linear feeding and shallow Z penetration.
        /// - Pros: Drastically reduces spindle load and tool tip heat compared to plunging; safe for non-center-cutting tools.
        /// - Cons: Requires clear linear length along the path to execute zig-zag passes.
        /// - Standard Use: Narrow slots, closed profile entries, and rectangular pocket clearings.
        ///
        /// - Parameter angleDegrees: Incline ramp entry angle relative to horizontal plane (typically 1.0°–5.0°).
        case ramp(angleDegrees: Double)

        /// Downward spiral motion in circular arcs down to cutting depth.
        ///
        /// - Real-World Impact: Rotates the cutter smoothly in X, Y, and Z simultaneously, evacuating chips effectively up tool flutes while descending.
        /// - Pros: Smooth continuous machine motion with minimum chatter; evenly distributes load across all flutes; gold standard for pocket entries.
        /// - Cons: Requires sufficient internal clearance area inside the pocket to accommodate helix radius.
        /// - Standard Use: Ideal default for 2D pockets, dynamic adaptive clearing, and deep internal cavities.
        ///
        /// The helix radius is not a parameter: the engine derives it from the tool (95% of the
        /// tool radius, so the cutter edge still sweeps across the helix axis), shrunk further
        /// when the pocket is too small for it. In a round pocket cleared inside-out, the helix is
        /// centered on the pocket's center.
        ///
        /// - Parameter rampAngleDegrees: Helical descent pitch angle relative to horizontal plane (typically 1.5°–3.0°).
        case helix(rampAngleDegrees: Double)

        /// Feeds in sideways from outside the stock, through an open end of the
        /// feature,
        /// Only meaningful for a feature that is genuinely open at the end the
        /// tool starts from -- e.g. a slot that runs off the edge of the stock --
        /// since it relies on there being no material at the starting point to
        /// rapid straight down into. The geometry itself is expected to already
        /// extend past that open end (see `openEndedSlotCenterline(fromBoundary:
        /// tool:)`), so this case only controls how the tool traces that geometry,
        /// not where the geometry starts.
        ///
        /// - Real-World Impact: Lets the tool reach full cutting depth before it
        ///   ever touches material, then sweep into the feature loop by loop --
        ///   each loop only partially engaged until it's fully inside the walls --
        ///   instead of engaging the full cutter width the instant it crosses the
        ///   stock edge.
        /// - Pros: No plunge/ramp/helix needed at all; avoids the sudden full-width
        ///   engagement a straight feed-in from outside would otherwise cause.
        /// - Cons: Only applicable where the feature is actually open to free air
        ///   on the side the tool approaches from.
        /// - Standard Use: Open-ended slots, keyways, and channels that run off
        ///   the edge of the stock.
        ///
        /// - Parameter stepoverPercentage: Forward advance between successive
        ///   bites, as a fraction (clamped to `0...1`) of `tool.diameter` -- the same
        ///   convention as `settings.cutting.stepoverPercentage`.
        case fromOpenEnd(stepoverPercentage: Double)
    }
}

extension SC.EntryStrategy {

    /// Entries that simply drop straight down at the start point (rapid above it, then feed
    /// down at the plunge rate). `.fromOpenEnd` only has its own, trochoidal, behaviour in
    /// `.slotting`; on any other operation it means the start point is in free air, so a
    /// straight drop is exactly what it asks for.
    var isStraightDown: Bool {
        switch self {
            case .plunge, .fromOpenEnd: return true
            case .ramp, .helix: return false
        }
    }
}
