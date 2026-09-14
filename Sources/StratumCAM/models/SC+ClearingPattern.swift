//
//  PocketType.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    public enum PocketClearingPattern: Sendable, Codable, Equatable {
        case offset
        case raster
        case spiral(direction: SpiralDirection)
        case morph
        case trochoidal(settings: TrochoidalSettings)
        case adaptive(settings: AdaptiveSettings)

        var strategy: ClearingPattern {
            switch self {
                case .offset:
                    return .offset

                case .raster:
                    return .raster

                case .spiral(let direction):
                    return .spiral(direction: direction)

                case .morph:
                    return .morph

                case .adaptive(let settings):
                    return .adaptive(settings: settings)

                case .trochoidal(let settings):
                    return .trochoidal(settings: settings)
            }
        }
    }

    public enum SlotClearingPattern: Sendable, Codable, Equatable {
        case raster
        case trochoidal(settings: TrochoidalSettings)
        case adaptive(settings: AdaptiveSettings)

        var strategy: ClearingPattern {
            switch self {
                case .raster:
                    return .raster

                case .adaptive(let settings):
                    return .adaptive(settings: settings)

                case .trochoidal(let settings):
                    return .trochoidal(settings: settings)
            }
        }
    }

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

    public struct AdaptiveSettings: Sendable, Codable, Equatable {
        /// Target radial engagement of the tool, in millimeters.
        /// Try to maintain <optimalLoad> mm radial engagement where geometry permits.
        var optimalLoad: Double

        public init(optimalLoad: Double) {
            self.optimalLoad = optimalLoad
        }
    }

    public struct TrochoidalSettings: Sendable, Codable, Equatable {
        /// Forward pitch between successive bounce cycles, as a fraction
        /// (clamped to `0...1`) of the tool's own radius
        let radialEngagement: Double

        // TODO: what is this?
        let loopRadius: Double

        public init(radialEngagement: Double, loopRadius: Double) {
            self.radialEngagement = radialEngagement
            self.loopRadius = loopRadius
        }
    }

    /// Defines the toolpath trajectory or material-removal strategy used
    /// to clear material within a pocket or other clearing region.
    ///
    /// A clearing pattern describes HOW the cutter traverses the material.
    /// It does not define what feature is being machined, how the tool
    /// enters the material, or the cutting direction; those concerns belong
    /// to `MachiningOperation`.
    public enum ClearingPattern: Sendable, Codable, Equatable {

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
        /// - Standard Use: General-purpose pocket clearing where predictable
        ///   boundary offsets are preferred.
        case offset

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
        case adaptive(settings: AdaptiveSettings)

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
        /// - Standard Use: Irregular pockets, mold cavities, pockets around
        ///   islands, and regions where inner and outer boundaries differ
        ///   significantly.
        case morph

        /// Forward-progressing looping or oscillating motion designed to keep
        /// radial cutter engagement relatively small.
        ///
        /// - Standard Use: Deep narrow slots, channels, keyways, and other
        ///   narrow regions requiring controlled radial engagement.
        case trochoidal(settings: TrochoidalSettings)
    }
}
