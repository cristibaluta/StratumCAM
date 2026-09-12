//
//  CAMStrategy.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    /// Defines the toolpath strategy used to machine a feature.
    ///
    /// Each strategy represents a different machining operation and contains
    /// the parameters required to generate its corresponding toolpath.
    public enum MachiningOperation: Sendable, Equatable {

        /// Cleans the top surface of the stock to establish a flat datum plane.
        case facing(stepover: Double, direction: CutDirection, extensionLength: Double)

        /// Cuts a linear slot or groove along a center curve.
        case slotting(depthPerPass: Double, entry: EntryStrategy)

        /// Mills threads into a pre-drilled hole or onto a boss.
        case tapping(pitch: Double, isInternal: Bool, direction: CutDirection)

        /// Engraves geometry along curves, text, or other shallow features.
        ///
        /// Typically follows the selected geometry directly with the tool centerline
        /// positioned according to the engraving operation's tool compensation rules.
        case engrave

        /// Machines the outside or inside wall of a closed profile.
        ///
        /// Supports conventional or climb cutting, controlled tool entry and exit,
        /// and optional holding tabs for keeping the workpiece attached to stock.
        ///
        /// - Parameters:
        ///   - side: Determines whether the tool cuts on the inside or outside
        ///     of the selected profile.
        ///   - direction: Determines the cutting direction, such as climb or
        ///     conventional milling.
        ///   - entry: Defines how the tool enters the material, for example by
        ///     plunging or ramping.
        ///   - leadIn: Optional lead-in move used to smoothly engage the profile
        ///     rather than entering directly on the cutting wall.
        ///   - leadOut: Optional lead-out move used to smoothly leave the profile
        ///     before retracting.
        ///   - tabs: Holding tabs left in the profile to prevent the finished
        ///     part from moving or separating from the stock during machining.
        case contour(side: CutSide,
                     direction: CutDirection,
                     entry: EntryStrategy,
                     leadIn: LeadInOut?,
                     leadOut: LeadInOut?,
                     tabs: [HoldingTab])

        /// Removes material from inside a closed boundary to create a pocket.
        ///
        /// The toolpath progressively clears the interior area while maintaining
        /// the selected cutting direction and pocketing pattern.
        ///
        /// - Parameters:
        ///   - direction: Determines the cutting direction, such as climb or
        ///     conventional milling.
        ///   - pocketType: Defines the pocket-clearing pattern or geometry strategy.
        ///   - entry: Defines how the tool enters the pocket, such as a ramp or
        ///     helical entry. Helical entry is useful for reducing the impact of
        ///     plunging directly into solid material.
        case pocket(direction: CutDirection,
                    pocketType: PocketType,
                    entry: EntryStrategy)

        /// Drills one or more holes at the specified locations.
        ///
        /// Optionally uses peck drilling, where the tool repeatedly retracts
        /// partially from the hole to evacuate chips and reduce heat.
        ///
        /// - Parameter peckDepth: Maximum depth of each drilling peck.
        ///   A value of `nil` indicates a continuous drilling operation without
        ///   pecking.
        case drilling(peckDepth: Double?)

        /// Machines a beveled edge using a chamfering tool.
        ///
        /// The chamfer parameters determine the resulting bevel geometry,
        /// cutting depth, and other operation-specific settings.
        ///
        /// - Parameter params: Parameters describing the desired chamfer geometry
        ///   and machining behavior.
        case chamfer(params: ChamferParams)

        /// Dynamically clears large amounts of material while maintaining a
        /// controlled cutter engagement.
        ///
        /// Adaptive clearing continuously adjusts the toolpath to maintain a
        /// relatively constant radial tool engagement. This allows aggressive
        /// material removal while reducing sudden changes in cutting load.
        ///
        /// - Parameters:
        ///   - type: Defines the adaptive clearing pattern or behavior.
        ///   - direction: Determines the cutting direction, such as climb or
        ///     conventional milling.
        ///   - optimalLoad: Target radial tool engagement in millimeters. The
        ///     generated toolpath attempts to maintain approximately this amount
        ///     of cutter engagement where geometry permits.
        ///   - entry: Defines how the cutter enters the material. Helical entry
        ///     is commonly used for entering solid stock without a full-depth
        ///     vertical plunge.
        case adaptiveClearing(type: AdaptiveType,
                              direction: CutDirection,
                              optimalLoad: Double,
                              entry: EntryStrategy)

        /// Enlarges an existing hole to precise diameter tolerances using a single-point tool.
        ///
        /// - Parameters:
        ///   - targetDiameter: The final finished diameter of the bored hole.
        ///   - dwellTime: Optional pause at the bottom of the bore to ensure true circularity.
        ///   - shiftRetract: Whether to shift the cutter off-center before retracting to preserve surface finish.
        case boring(targetDiameter: Double, dwellTime: Double?, shiftRetract: Bool)
    }
}
