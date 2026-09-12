//
//  Side.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    /// Defines tool center offset relative to selected target geometry.
    public enum CutSide: String, Sendable, Codable, Equatable {

        /// Tool cuts inside the profile, offset inward by half the cutter diameter.
        ///
        /// ```text
        /// ┌─────────────────────────┐
        /// │      Part Boundary      │
        /// │   ┌─────────────────┐   │
        /// │   │ Tool Centerline │───┼───► (Tool cutter stays inside)
        /// │   └─────────────────┘   │
        /// └─────────────────────────┘
        /// ```
        ///
        /// - Real-World Impact: Offsets tool center inward by radius `(diameter / 2)` so finished cavity matches exact boundary dimensions.
        /// - Pros: Preserves exact interior geometry dimensions on female features.
        /// - Cons: Cutter must fit inside tightest internal corner radius to prevent binding or error.
        /// - Standard Use: Interior cutout pockets, bored holes, window cutouts, and female inlay cavities.
        case inside

        /// Tool cuts outside the profile, offset outward by half the cutter diameter.
        ///
        /// ```text
        ///     ┌─────────────────────┐
        ///     │   Tool Centerline   │───► (Tool cutter stays outside)
        ///   ┌─┴─────────────────────┴─┐
        ///   │      Part Boundary      │
        ///   └─────────────────────────┘
        /// ```
        ///
        /// - Real-World Impact: Offsets tool center outward by radius `(diameter / 2)` so finished outer part size matches exact design geometry.
        /// - Pros: Delivers exact external part dimensions on male features.
        /// - Cons: Requires extra stock clearance around outer perimeter to prevent tool collision with clamps or raw material edge.
        /// - Standard Use: Outer part perimeter cutting, male boss profiles, and male inlay pieces.
        case outside

        /// Tool centerline follows selected geometry directly with zero lateral cutter compensation.
        ///
        /// ```text
        ///        Tool Centerline
        /// ─────────────•─────────────  ───► (Tool center follows path directly)
        ///        Part Geometry
        /// ```
        ///
        /// - Real-World Impact: Cuts directly along selected geometry vector, leaving half cutter radius on both left and right sides.
        /// - Pros: Simple 2D tracking with no tool radius compensation calculation needed.
        /// - Cons: Slot width or cut width equals full cutter diameter; cannot adjust dimensions via compensation.
        /// - Standard Use: Engraving text/lines, V-carving centerlines, slotting grooves, and decorative line cuts.
        case onContour
    }
}
