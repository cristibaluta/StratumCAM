//
//  AdaptiveType.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    /// Defines the domain boundary target and path generation mode for adaptive (constant radial load) clearing.
    public enum AdaptiveType: String, Sendable, Codable, Equatable {

        /// Clears volumetric material within an enclosed interior pocket boundary or open stock boundary.
        ///
        /// ```text
        /// ┌─────────────────────────┐
        /// │  ╭──╮   ╭──╮   ╭──╮     │
        /// │ ╭┘  └╮ ╭┘  └╮ ╭┘  └╮    │ ───► (Clears internal pocket volume
        /// │ ╰┐  ┌╯ ╰┐  ┌╯ ╰┐  ┌╯    │       maintaining constant radial engagement)
        /// │  ╰──╯   ╰──╯   ╰──╯     │
        /// └─────────────────────────┘
        /// ```
        ///
        /// - Real-World Impact: Morphologically clears entire enclosed stock cavities or open regions,
        ///   dynamically shrinking or expanding trochoidal-like arcs to ensure cutter engagement never
        ///   exceeds `optimalLoad`.
        /// - Pros: Eliminates full-width cutter jamming in corners; enables deep axial cuts (100%–200% tool diameter)
        ///   at maximum feed rates.
        /// - Cons: Generates high line-count G-code; requires rapid acceleration capabilities on machine axes.
        /// - Standard Use: Pocket roughing, interior cavity clearing, and heavy stock removal in hard metals or wood.
        case clearing2D

        /// Follows an open or closed exterior profile wall, progressively peeling back material from the outside in.
        ///
        /// ```text
        ///         │ ╭──╮   ╭──╮   ╭──╮
        ///  Part   │╭┘  └╮ ╭┘  └╮ ╭┘  └╮ ───► (Peels material inward toward profile
        ///  Wall   │╰┐  ┌╯ ╰┐  ┌╯ ╰┐  ┌╯      wall without slamming into corners)
        ///         │ ╰──╯   ╰──╯   ╰──╯
        /// ────────┴───────────────────
        /// ```
        ///
        /// - Real-World Impact: Clears material along complex outer profile contours using adaptive engagement arcs
        ///   instead of taking a single heavy, full-width profile pass.
        /// - Pros: Prevents tool deflection and binding when roughing heavy outer walls or steep corners;
        ///   leaves a uniform stock allowance for the final contour finishing pass.
        /// - Cons: Creates longer path lengths than a simple multi-pass offset profile toolpath.
        /// - Standard Use: Roughing thick outer part profiles, high-speed perimeter carving, and removing heavy stock around standing bosses.
        case adaptiveContour
    }
}
