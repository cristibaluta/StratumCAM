//
//  CAMStrategy.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    /// Defines the machining operation performed on the selected geometry.
    ///
    /// The operation describes WHAT feature is being machined and owns
    /// operation-wide behavior such as cutting direction and tool entry.
    /// For pocketing, `ClearingPattern` describes HOW the material inside
    /// the pocket is removed.
    public enum MachiningOperation: Sendable, Equatable {

        /// Cleans the top surface of the stock to establish a flat datum plane.
        ///
        /// - Parameters:
        ///   - stepover: Lateral distance between successive facing passes.
        ///   - direction: Cutting direction used for the facing passes.
        ///   - extensionLength: Distance by which the toolpath extends beyond
        ///     the selected facing boundary to ensure complete coverage.
        case facing(stepover: Double,
                    direction: CutDirection,
                    extensionLength: Double)

        /// Cuts a linear slot or groove along a center curve.
        ///
        /// Slotting describes the feature being machined. The actual material
        /// removal strategy may be implemented using direct slotting, helical
        /// entry, trochoidal motion, or another strategy as appropriate to the
        /// operation and toolpath generator.
        ///
        /// - Parameters:
        ///   - depthPerPass: Maximum axial depth removed during each cutting pass.
        ///   - entry: Strategy used to enter the slot material.
        case slotting(depthPerPass: Double, entry: EntryStrategy)

        /// Mills threads into a pre-drilled hole or onto a boss.
        ///
        /// - Parameters:
        ///   - pitch: Thread pitch.
        ///   - isInternal: Whether the thread is internal or external.
        ///   - direction: Cutting direction used for the threading motion.
        case threadMilling(pitch: Double,
                     isInternal: Bool,
                     direction: CutDirection)

        /// Engraves geometry along curves, text, or other shallow features.
        ///
        /// Typically follows the selected geometry directly with the tool
        /// centerline positioned according to the engraving operation's
        /// tool compensation rules.
        case engrave

        /// Machines the outside or inside wall of a closed profile.
        ///
        /// Supports conventional or climb cutting, controlled tool entry and
        /// exit, and optional holding tabs for keeping the workpiece attached
        /// to stock.
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
        /// The operation progressively clears the interior area using the
        /// selected clearing pattern while maintaining the selected cutting
        /// direction and entry strategy.
        ///
        /// ```text
        /// ┌─────────────────────────┐
        /// │         POCKET          │
        /// │                         │
        /// │   ┌─────────────────┐   │
        /// │   │                 │   │
        /// │   │   TOOLPATH      │   │
        /// │   │     ↓↓↓↓↓       │   │
        /// │   │   MATERIAL      │   │
        /// │   │   REMOVAL       │   │
        /// │   │                 │   │
        /// │   └─────────────────┘   │
        /// │                         │
        /// └─────────────────────────┘
        /// ```
        ///
        /// - Parameters:
        ///   - direction: Determines the cutting direction, such as climb or
        ///     conventional milling.
        ///   - pattern: Defines how the material inside the pocket is cleared,
        ///     such as offset, raster, adaptive, spiral, morph, or trochoidal.
        ///   - entry: Defines how the cutter enters the pocket, such as a plunge,
        ///     ramp, or helical entry.
        ///
        /// - Note: Adaptive clearing is represented as a `ClearingPattern`
        ///   because adaptive describes HOW the pocket material is removed,
        ///   rather than WHAT machining feature is being performed.
        case pocket(direction: CutDirection,
                    pattern: PocketClearingPattern,
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
        /// - Parameter params: Parameters describing the desired chamfer geometry,
        ///   cutting depth, and other operation-specific settings.
        case chamfer(params: ChamferParams)

        /// Enlarges an existing hole to precise diameter tolerances using
        /// a single-point tool.
        ///
        /// - Parameters:
        ///   - targetDiameter: Final finished diameter of the bored hole.
        ///   - dwellTime: Optional pause at the bottom of the bore to help
        ///     maintain circularity and surface finish.
        ///   - shiftRetract: Whether to shift the cutter off-center before
        ///     retracting to reduce the chance of marking the finished bore wall.
        case boring(targetDiameter: Double,
                    dwellTime: Double?,
                    shiftRetract: Bool)
    }
    
}
