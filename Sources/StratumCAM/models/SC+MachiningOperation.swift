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
        /// There's no `stepover` parameter: the row spacing between facing passes
        /// is derived from the tool's own diameter (see
        /// `SCEngine.facingStepover(for:)`), close to full engagement since facing
        /// has no wall to protect the way a pocket does -- there's nothing here for
        /// a caller to tune, only a footprint to fully cover.
        ///
        /// - Parameters:
        ///   - direction: Cutting direction used for the facing passes.
        ///   - extensionLength: Distance by which the toolpath extends beyond
        ///     the selected facing boundary to ensure complete coverage.
        case facing(direction: CutDirection,
                    extensionLength: Double)

        /// Cuts a linear slot or groove along a center curve or constrained by 2 walls
        ///
        /// Slotting describes the feature being machined. The actual material
        /// removal strategy may be implemented using direct slotting, helical
        /// entry, trochoidal motion, or another strategy as appropriate to the
        /// operation and toolpath generator.
        ///
        /// - Parameters:
        ///   - depthPerPass: Maximum axial depth removed during each cutting pass.
        ///   - entry: Strategy used to enter the slot material.
        case slotting(depthPerPass: Double,
                      pattern: SlotClearingPattern,
                      entry: EntryStrategy)

        /// - Parameters:
        ///   - pitch: Thread pitch.
        ///   - isInternal: Whether the thread is internal or external.
        ///   - direction: Handedness of the thread being cut -- right-hand or
        ///     left-hand -- which determines which way the helix winds. This is
        ///     not a `CutDirection` (climb/conventional): climb/conventional
        ///     describes chip load for a generic milling pass, and isn't a
        ///     meaningful choice for a thread mill, whose winding sense is fixed
        ///     by the handedness of the thread it's cutting.
        ///   - radialPasses: Number of radial passes used to step from the
        ///     existing diameter (the selected circle) to `targetDiameter`. Each
        ///     pass retraces the full helix (bottom to top) at its own diameter,
        ///     with the last pass landing exactly on `targetDiameter`. Usually 2
        ///     or 3; must be at least 1.
        ///   - targetDiameter: Finished (nominal/major) thread diameter to reach
        ///     on the last radial pass.
        case threadMilling(pitch: Double,
                           isInternal: Bool,
                           direction: ThreadDirection,
                           radialPasses: Int,
                           targetDiameter: Double)

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

        /// Machines a shallow, flat-bottomed recess around an existing hole -- e.g. so a
        /// screw head sits flush or buried -- using an ordinary end mill rather than a
        /// dedicated counterbore/spot-face cutter, which most desktop CNC users don't have.
        ///
        /// The whole point of this being its own operation rather than just drawing the
        /// recess as a circle and running `.pocket` on it: there's nothing to draw. The
        /// recess is derived entirely from `diameter` and `depth` around the same
        /// point/closed-circle hole marker `.drilling`/`.boring` already recognize
        /// (`Contour.drillPoint`) -- mark the hole, say how wide and how deep the
        /// counterbore should be, done.
        ///
        /// Cut as concentric circular rings growing outward from the hole's own center,
        /// one full stepover band at a time (mirroring `.pocket`'s `.offset` ring stack,
        /// just built directly from a center point and a diameter instead of offsetting a
        /// drawn boundary), repeated at each of several Z depths -- not a single continuous
        /// helical descent that reaches full radius and full depth at once, which would let
        /// radial engagement grow with however wide the recess is by the time it bottoms
        /// out.
        ///
        /// - Parameters:
        ///   - diameter: Finished diameter of the counterbore recess.
        ///   - depth: Depth of the counterbore recess below the top surface -- separate
        ///     from `MachineSettings.targetDepth`, since a job can easily mix holes needing
        ///     different screw-head depths.
        ///   - direction: Determines the cutting direction, such as climb or conventional
        ///     milling.
        ///   - entry: Defines how the tool enters the material for the first ring of each
        ///     Z pass, for example by plunging, ramping, or a helical spiral.
        case counterbore(diameter: Double,
                         depth: Double,
                         direction: CutDirection,
                         entry: EntryStrategy)
    }

}
