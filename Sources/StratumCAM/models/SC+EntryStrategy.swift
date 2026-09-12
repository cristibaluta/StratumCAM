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
        /// ```text
        ///          │  │ (Tool)
        ///          │  │
        ///          ▼  ▼
        ///     ─────────────── (Stock Surface)
        ///          │  │
        ///          ▼  ▼
        /// ```
        ///
        /// - Real-World Impact: Drives the end mill straight down along the Z-axis into material.
        /// - Pros: Fastest entry method; minimal XY movement during entry.
        /// - Cons: Highest Z-axis cutting load; non-center-cutting end mills will burn or break; causes severe tip wear in hard materials.
        /// - Standard Use: Pre-drilled entry holes, soft materials (foams/plastics), or cutting off the edge of stock in open air.
        case plunge

        /// Zig-zag motion back and forth at a shallow incline angle down to cut depth.
        ///
        /// ```text
        ///          │  │ (Tool)
        ///          \  \
        ///           \  \  /  /
        ///            \  \/  /
        ///             \    / ───► (Zig-zag ramp entry at angle θ)
        ///              \  /
        ///     ──────────\/───
        /// ```
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
        /// ```text
        ///           ╭───╮
        ///          ╭┘   └╮
        ///         ╭┘ ╭─╮ └╮ ───► (Continuous helical spiral entry)
        ///        ╭┘  │•│  └╮
        ///       ─┴───┴─┴───┴─
        /// ```
        ///
        /// - Real-World Impact: Rotates the cutter smoothly in X, Y, and Z simultaneously, evacuating chips effectively up tool flutes while descending.
        /// - Pros: Smooth continuous machine motion with minimum chatter; evenly distributes load across all flutes; gold standard for pocket entries.
        /// - Cons: Requires sufficient internal clearance area inside the pocket to accommodate helix radius.
        /// - Standard Use: Ideal default for 2D pockets, dynamic adaptive clearing, and deep internal cavities.
        ///
        /// - Parameters:
        ///   - radius: Radius of helical spiral entry path in workspace units (mm/inches).
        ///   - rampAngleDegrees: Helical descent pitch angle relative to horizontal plane (typically 1.5°–3.0°).
        case helix(radius: Double, rampAngleDegrees: Double)
    }
}
