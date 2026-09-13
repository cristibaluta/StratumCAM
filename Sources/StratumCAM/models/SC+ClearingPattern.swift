//
//  PocketType.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    /// Defines the toolpath trajectory or material-removal strategy used
    /// to clear material within a pocket or other clearing region.
    ///
    /// A clearing pattern describes HOW the cutter traverses the material.
    /// It does not define what feature is being machined, how the tool
    /// enters the material, or the cutting direction; those concerns belong
    /// to `MachiningOperation`.
    public enum ClearingPattern: Sendable, Codable, Equatable {

        /// Which end of the ring stack a `.spiral` pocket starts and finishes at.
        ///
        /// This controls the ordering of the spiral passes, not the cutting
        /// direction (`climb` / `conventional`), which is controlled separately
        /// by `MachiningOperation`.
        public enum SpiralDirection: String, Sendable, Codable, Equatable {

            /// Opening turn holds at the outer (wall) radius; closing turn holds
            /// at the innermost radius.
            ///
            /// The tool engages the wall first and clears toward the center,
            /// leaving the innermost region for the final part of the operation.
            case outsideIn

            /// Opening turn holds at the innermost radius; closing turn holds
            /// at the outer (wall) radius.
            ///
            /// The final outward pass approaches the wall last, which can be
            /// useful when the final wall pass should not be followed by
            /// another interior clearing pass.
            case insideOut
        }

        /// Concentric paths following successive offsets of the pocket boundary,
        /// stepping inward or outward.
        ///
        /// ```text
        /// ┌───────────────────────┐
        /// │ ┌───────────────────┐ │
        /// │ │ ┌───────────────┐ │ │
        /// │ │ │   ┌───────┐   │ │ │
        /// │ │ │   │ Start │───┼─┼─┼───►
        /// │ │ │   └───────┘   │ │ │   (Concentric Offsets)
        /// │ │ └───────────────┘ │ │
        /// │ └───────────────────┘ │
        /// └───────────────────────┘
        /// ```
        ///
        /// - Real-World Impact: Produces predictable, boundary-following passes
        ///   with relatively uniform motion around the pocket.
        ///
        /// - Pros: Simple, predictable, and effective for pockets with regular
        ///   boundaries.
        ///
        /// - Cons: Offset geometry can create difficult transitions or sharp
        ///   directional changes in complex concave geometry.
        ///
        /// - Standard Use: General-purpose pocket clearing where predictable
        ///   boundary offsets are preferred.
        case offsetPattern

        /// Parallel linear scanlines across the clearing region.
        ///
        /// ```text
        /// ┌───────────────────────┐
        /// │ ◄───────────────────┐ │
        /// │ ├───────────────────┘ │
        /// │ └───────────────────┐ │
        /// │ ┌───────────────────┘ │
        /// │ └───────────────────► │
        /// └───────────────────────┘
        /// ```
        ///
        /// - Real-World Impact: Uses simple, predictable linear passes to sweep
        ///   across the available material.
        ///
        /// - Pros: Easy to compute, predictable, and effective for simple
        ///   rectangular or open clearing regions.
        ///
        /// - Cons: Requires frequent direction changes or linking moves at
        ///   boundaries and may leave scallops or directional marks that require
        ///   a separate finishing pass.
        ///
        /// - Standard Use: Simple pockets, facing-like clearing, and open areas.
        case raster

        /// Dynamic roughing strategy that adapts the cutter trajectory to the
        /// remaining material in order to maintain controlled cutter engagement.
        ///
        /// ```text
        /// ┌────────────────────────────┐
        /// │   ╭──╮    ╭──╮             │
        /// │ ╭─╯  ╰────╯  ╰─╮           │
        /// │ ╰╮             ╭╯  ───►     │
        /// │   ╰─────────────╯           │
        /// └────────────────────────────┘
        /// ```
        ///
        /// Unlike a fixed offset or raster pattern, the trajectory can change
        /// locally as the available material changes. Around corners, islands,
        /// narrow regions, and changing boundaries, the path is adjusted to
        /// avoid sudden increases in cutter engagement.
        ///
        /// - Real-World Impact: Keeps cutter engagement relatively controlled,
        ///   reducing cutting-force spikes and allowing efficient high-feed
        ///   roughing with relatively low radial engagement.
        ///
        /// - Pros: Handles complex pocket geometry well and adapts the trajectory
        ///   to changing material conditions.
        ///
        /// - Cons: More computationally complex than fixed offset or raster
        ///   clearing and may generate more complex toolpaths.
        ///
        /// - Standard Use: High-efficiency roughing of pockets, cavities,
        ///   irregular boundaries, and regions with changing material engagement.
        ///
        /// - Parameters:
        ///   - type: Defines the adaptive clearing behavior.
        ///   - optimalLoad: Target radial cutter engagement, in millimeters.
        ///     The generated path attempts to maintain approximately this
        ///     engagement where the geometry permits.
        case adaptive(
            type: AdaptiveType,
            optimalLoad: Double
        )

        /// Continuous smooth spiral expanding from the center outward or
        /// collapsing inward.
        ///
        /// ```text
        /// ┌──────────────────────┐
        /// │      ╭─────────╮     │
        /// │    ╭─╯         ╰─╮   │
        /// │   │    ╭─────╮    │  │
        /// │   │   ╱   •   ╲   │  │ ───►
        /// │   │   ╰───────╯   │  │
        /// │    ╰─────────────╯   │
        /// └──────────────────────┘
        /// ```
        ///
        /// - Real-World Impact: Provides continuous tool motion with fewer
        ///   abrupt directional changes than independent offset passes.
        ///
        /// - Pros: Smooth motion and efficient linking between successive
        ///   regions when the pocket geometry is suitable for a spiral.
        ///
        /// - Cons: Best suited to circular, elliptical, or otherwise smooth
        ///   boundaries. Irregular geometry may require a fallback strategy.
        ///
        /// - Standard Use: Circular pockets, bores, smooth cavities, and
        ///   suitable facing or clearing regions.
        ///
        /// - Parameter:
        ///   - direction: Determines whether the spiral progresses from the
        ///     outside toward the inside or from the inside toward the outside.
        case spiral(direction: SpiralDirection)

        /// Smoothly interpolates paths between two differing inner and outer
        /// boundaries.
        ///
        /// ```text
        /// ┌───────────────────────┐
        /// │     ╭──────────╮      │
        /// │   ╭─╯──────────╰─╮    │
        /// │  │    ╭──────╮    │   │
        /// │  │   │   ( )  │    │   │ ───►
        /// │  │    ╰──────╯    │   │
        /// │   ╰─╮──────────╭─╯    │
        /// │     ╰──────────╯      │
        /// └───────────────────────┘
        /// ```
        ///
        /// - Real-World Impact: Gradually morphs the toolpath geometry between
        ///   inner and outer boundaries instead of relying solely on independent
        ///   offsets.
        ///
        /// - Pros: Can distribute passes smoothly across irregular or
        ///   non-concentric cavities.
        ///
        /// - Cons: More computationally complex and requires suitable boundary
        ///   geometry to avoid undesirable self-intersections or abrupt changes.
        ///
        /// - Standard Use: Irregular pockets, mold cavities, pockets around
        ///   islands, and regions where inner and outer boundaries differ
        ///   significantly.
        case morph

        /// Forward-progressing looping or oscillating motion designed to keep
        /// radial cutter engagement relatively small.
        ///
        /// ```text
        /// ┌────────────────────────────┐
        /// │ ╭╮  ╭╮  ╭╮  ╭╮  ╭╮  ╭╮    │
        /// │ │╰──╯│  │╰──╯│  │╰──╯│     │ ───►
        /// │ ╰────╯  ╰────╯  ╰────╯     │
        /// └────────────────────────────┘
        /// ```
        ///
        /// The cutter does not normally complete a circle, stop, advance by
        /// a discrete step, and then repeat. Instead, forward motion and the
        /// lateral/looping motion occur continuously, producing a succession
        /// of overlapping arcs or loops as the cutter advances.
        ///
        /// - Real-World Impact: Keeps radial engagement relatively small during
        ///   slot or channel cutting, reducing cutting forces, heat, and the
        ///   risk of chip packing compared with conventional full-width slotting.
        ///
        /// - Pros: Particularly effective for deep narrow slots and channels
        ///   where full-width cutter engagement would overload the tool.
        ///
        /// - Cons: Produces a longer toolpath than a direct single-pass slot
        ///   and may be unnecessary when the desired radial engagement is already
        ///   small.
        ///
        /// - Standard Use: Deep narrow slots, channels, keyways, and other
        ///   narrow regions requiring controlled radial engagement.
        ///
        /// - Note: Trochoidal motion is a specific trajectory technique.
        ///   Adaptive clearing may also generate trochoidal-like looping motion
        ///   as part of its dynamic engagement-control strategy.
        case trochoidal
    }
}
