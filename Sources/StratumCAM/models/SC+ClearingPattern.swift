//
//  PocketType.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    /// Defines the toolpath trajectory pattern used to clear material across pockets, facing passes, or open areas.
    public enum ClearingPattern: Sendable, Codable, Equatable {

        /// Which end of the ring stack a `.spiral` pocket starts and finishes at.
        ///
        /// - Standard Use: `.outsideIn` (the default) engages the wall first while the
        ///   tool is fresh and clears the floor last; `.insideOut` enters near the center
        ///   and finishes with a single, uninterrupted wall pass for jobs where wall
        ///   finish matters most, mirroring canned circular-pocket cycles like Fanuc
        ///   G12/G13.
        public enum SpiralDirection: String, Sendable, Codable, Equatable {

            /// Opening turn holds at the outer (wall) radius; closing turn holds at the
            /// innermost radius. The tool engages the wall first and clears the floor last.
            case outsideIn

            /// Opening turn holds at the innermost radius; closing turn holds at the
            /// outer (wall) radius, so nothing re-touches the wall after that final pass.
            case insideOut
        }

        /// Concentric paths mirroring the boundary shape, stepping inward or outward.
        ///
        /// ```text
        /// ┌───────────────────────┐
        /// │ ┌───────────────────┐ │
        /// │ │ ┌───────────────┐ │ │
        /// │ │ │   ┌───────┐   │ │ │
        /// │ │ │   │ Start │───┼─┼─┼───► (Concentric Offsets)
        /// │ │ │   └───────┘   │ │ │
        /// │ │ └───────────────┘ │ │
        /// │ └───────────────────┘ │
        /// └───────────────────────┘
        /// ```
        ///
        /// - Real-World Impact: Maintains continuous cutter engagement and minimizes sharp directional changes,
        ///   producing a smooth, uniform wall finish.
        /// - Pros: Very efficient; leaves clean pocket walls without extra finishing passes.
        /// - Cons: Can create sharp inner-corner directional spikes in complex geometric shapes.
        /// - Standard Use: Default choice for standard rectangular, circular, or smooth organic pockets.
        case offsetPattern

        /// Parallel linear scanlines across the material.
        ///
        /// ```text
        /// ┌───────────────────────┐
        /// │ ◄───────────────────┐ │
        /// │ ├───────────────────┘ │
        /// │ └───────────────────┐ │
        /// │ ┌───────────────────┘ │
        /// │ └───────────────────► │ (Parallel Scanlines)
        /// └───────────────────────┘
        /// ```
        ///
        /// - Real-World Impact: Simple and predictable tool motion, but forces frequent tool retractions
        ///   or direction reversals at pocket walls.
        /// - Pros: Highly reliable for simple or rectangular stock; easy to compute.
        /// - Cons: Frequently switches between climb and conventional cutting unless forced to single-direction raster;
        ///   leaves a scalloped wall that requires a separate contour finishing pass.
        /// - Standard Use: Used for simple rectangular cutouts, facing-like top clearing, or machines with limited memory.
        case raster

        /// Dynamic curvature-controlled paths maintaining constant radial load.
        ///
        /// ```text
        /// ┌───────────────────────┐
        /// │  ╭──╮  ╭──╮  ╭──╮     │
        /// │ ╭┘  └╮╭┘  └╮╭┘  └╮    │ ───► (Constant Radial Engagement)
        /// │ ╰┐  ┌╯╰┐  ┌╯╰┐  ┌╯    │
        /// │  ╰──╯  ╰──╯  ╰──╯     │
        /// └───────────────────────┘
        /// ```
        ///
        /// - Real-World Impact: Continuously adjusts tool motion to maintain a strict, light radial engagement (typically 10%–20%),
        ///   allowing maximum axial depth of cut without tool overload.
        /// - Pros: Eliminates corner spikes, drastically reduces heat/tool wear, and achieves extreme material removal rates (MRR).
        /// - Cons: Generates significantly larger G-code files due to continuous high-density arc motion.
        /// - Standard Use: High-efficiency roughing in tough materials (metals, hard woods) or deep pockets.
        case adaptive

        /// Continuous smooth spiral expanding from center outward or collapsing inward.
        ///
        /// ```text
        /// ┌──────────────────────┐
        /// │     ╭─────────╮      │
        /// │   ╭─┴───────╮ │      │
        /// │   │ ╭───╮   │ │      │ ───► (Continuous Spiral)
        /// │   │ │ • │   │ │      │
        /// │   │ ╰───╯   │ │      │
        /// │   ╰─-───────╯ │      │
        /// └──────────────────────┘
        /// ```
        ///
        /// - Real-World Impact: Maintains unbroken cutter contact with zero sharp directional shifts or stepover retractions.
        /// - Pros: Extremely smooth machine motion; produces superior circular pocket floor finishes and minimizes machine chatter.
        /// - Cons: Limited applicability; only works well on circular, elliptical, or near-symmetrical smooth boundaries.
        /// - Standard Use: Circular bore clearing, circular pockets, and smooth circular facing operations.
        ///
        /// - Parameter direction: Which end of the ring stack the spiral starts and
        ///   finishes at -- see `SpiralDirection`. Only takes effect once a boundary is
        ///   already spiral-eligible (see `isSpiralEligible`); the non-circular fallback
        ///   path is the same regardless of `direction`.
        case spiral(direction: SpiralDirection)

        /// Smoothly interpolates paths between two differing inner and outer boundaries.
        ///
        /// ```text
        /// ┌───────────────────────┐
        /// │     ╭──────────╮      │
        /// │   ╭─┴──────────┴─╮    │
        /// │  │   ╭────────╮   │   │ ───► (Transitions between inner/outer shapes)
        /// │  │  │  (  )   │   │   │
        /// │   ╰─┬──────────┬─╯    │
        /// └───────────────────────┘
        /// ```
        ///
        /// - Real-World Impact: Gradually morphs path geometry from an inner boundary shape to a completely different outer boundary shape.
        /// - Pros: Distributes stepover passes evenly across irregular non-concentric cavities without creating uneven stock ridges.
        /// - Cons: Computationally heavy and harder to compute for self-intersecting complex curves.
        /// - Standard Use: Pocketing around islands, mold cavities, or irregular geometry transitions.
        case morph

        /// Circular overlapping loop motion designed for narrow slots or channel clearing.
        ///
        /// ```text
        /// ┌───────────────────────┐
        /// │ ╭╮ ╭╮ ╭╮ ╭╮ ╭╮ ╭╮ ╭╮  │
        /// │ ││ ││ ││ ││ ││ ││ ││  │ ───► (Overlapping Circular Loops)
        /// │ ╰╯ ╰╯ ╰╯ ╰╯ ╰╯ ╰╯ ╰╯  │
        /// └───────────────────────┘
        /// ```
        ///
        /// - Real-World Impact: Advances the cutter through a channel in overlapping circular loops, keeping radial engagement low even in full-width cuts.
        /// - Pros: Prevents tool binding and chip packing when cutting narrow slots that match or slightly exceed cutter diameter.
        /// - Cons: Takes longer total distance travel than a straight single-pass slotting operation.
        /// - Standard Use: Deep narrow slots, keyways, or high-speed roughing of narrow channels.
        case trochoidal
    }
}
