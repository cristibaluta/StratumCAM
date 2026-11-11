//
//  SCEngine+Pocket3D.swift
//  StratumCAM
//
//  `.pocket3D`: a pocket cleared in layers from the top, where every island has its own top
//  height (`SC.Contour.topZ`). See PLAN_3D_POCKETING.md; this is phase 1 (roughing only).
//
//  The idea: islands are vertical-walled columns, so the XY geometry of the pocket only
//  changes at the Z of an island top. The Z range is split into bands of layers that share
//  the same set of standing islands; each band is planned once with the ordinary 2D pocket
//  machinery (`planPocket`) and emitted layer by layer (`pocketPassWaypoints`).
//

import Foundation
import CoreGraphics

extension SCEngine {

    // MARK: - Layout: layers and bands

    /// A stretch of consecutive layers that all have the same islands standing.
    struct Pocket3DBand: Equatable {
        /// The floor Z of each layer, top to bottom.
        var layers: [Double]
        /// The islands in the way during these layers, as indices into the island list given to
        /// `pocket3DLayout` (ascending).
        var activeIslands: [Int]
    }

    /// How a 3D pocket is split into layers and bands.
    struct Pocket3DLayout: Equatable {
        /// Top to bottom. Bands are never empty.
        var bands: [Pocket3DBand]
        /// Islands (indices) whose top is at or below the floor: they never stand, so they are
        /// left out of every band.
        var ignoredIslands: [Int]

        /// The floor Z of every layer, top to bottom.
        var layers: [Double] {
            bands.flatMap { $0.layers }
        }
    }

    /// Distance below which two Z values count as the same level (mm).
    static let pocket3DTolerance = 1e-6

    /// Works out the layers of a 3D pocket and which islands are in the way of each one.
    ///
    /// - Parameter islandTops: each island's `topZ` (Z0 = top of the stock, negative downwards,
    ///   used as given). `nil`, or zero and above, is a boss: it is in the way of every layer
    ///   and creates no breakpoint. At or below the floor the island never stands and is
    ///   reported in `ignoredIslands`. Anything in between is a stepped island: the layers land
    ///   exactly on its top.
    ///
    /// `targetDepth` and `stepdown` are the `MachineSettings` ones (the depth is read as `abs`).
    ///
    /// A layer is cut at the Z that ends it; an island is in its way when the island's top is
    /// above that Z. So the layer that ends exactly on an island's top is not blocked by it
    /// (that layer is the one that creates the island's flat top), and the next one is.
    func pocket3DLayout(islandTops: [Double?], targetDepth: Double, stepdown: Double) -> Pocket3DLayout {

        let tolerance = SCEngine.pocket3DTolerance
        let floorZ = -abs(targetDepth)

        // The height each island is treated with: +infinity for a boss, nil when ignored.
        var heights: [Double?] = []
        var ignored: [Int] = []
        var breakpoints: [Double] = []

        for (index, declared) in islandTops.enumerated() {
            let top = declared ?? Double.infinity
            if top.isNaN || top >= 0 {
                heights.append(Double.infinity)
            } else if top <= floorZ + tolerance {
                heights.append(nil)
                ignored.append(index)
            } else {
                heights.append(top)
                breakpoints.append(top)
            }
        }

        let layers = EngineTools.calculateLayeredZPasses(targetDepth: targetDepth,
                                                         stepdown: stepdown,
                                                         breakpoints: breakpoints,
                                                         tolerance: tolerance)

        var bands: [Pocket3DBand] = []
        for z in layers {
            let active = heights.indices.filter { index in
                guard let top = heights[index] else {
                    return false
                }
                return top > z + tolerance
            }
            if let last = bands.last, last.activeIslands == active {
                bands[bands.count - 1].layers.append(z)
            } else {
                bands.append(Pocket3DBand(layers: [z], activeIslands: active))
            }
        }

        return Pocket3DLayout(bands: bands, ignoredIslands: ignored)
    }

    // MARK: - Toolpath

    /// A pocket cleared in layers from the top, around the islands that stand in each layer.
    ///
    /// One `OutputToolpath` for the pocket, with all layers in one `passes` array in
    /// top-to-bottom order (`passIndex` runs across all bands, `depthZ` is the layer floor).
    /// Where the islands cut a band's pocket into several pieces (an island standing on the
    /// wall), the pieces of that layer share one pass.
    ///
    /// Phase 1 roughs only, straight to size: stock to leave and a finishing pass are refused
    /// rather than silently ignored.
    func buildPocket3DToolpath(for contour: SC.Contour,
                               tool: SC.ToolParams,
                               settings: SC.MachineSettings,
                               direction: SC.CutDirection,
                               pattern: SC.PocketClearingPattern,
                               entry: SC.EntryStrategy,
                               operation: SC.MachiningOperation) throws -> SC.OutputToolpath {

        guard contour.isClosed else {
            throw SC.Error.contourNotClosed
        }
        guard settings.allowance <= 1e-9, !settings.finishingPass else {
            throw SC.Error.invalidParameter("allowance")
        }
        // The height of a shape standing inside an island is not defined.
        guard !contour.islands.contains(where: { !$0.islands.isEmpty }) else {
            throw SC.Error.invalidParameter("nested islands are not supported")
        }

        let toolRadius = tool.diameter / 2.0
        let floorZ = -abs(settings.targetDepth)

        let layout = pocket3DLayout(islandTops: contour.islands.map { $0.topZ },
                                    targetDepth: settings.targetDepth,
                                    stepdown: settings.cutting.stepdown)

        var warnings: [SC.Warning] = []
        for index in layout.ignoredIslands {
            if let top = contour.islands[index].topZ {
                warnings.append(.islandBelowFloor(topZ: top, floorZ: floorZ))
            }
        }
        if abs(floorZ) > tool.fluteLength + 1e-9 {
            warnings.append(.depthExceedsFluteLength(depth: abs(floorZ), fluteLength: tool.fluteLength))
        }

        // Checked once, before any layer is built, so the toolpath can't be fine in the
        // island-free bands and fail halfway in the others. Only an island that stands counts:
        // with none (none drawn, or all below the floor) every pattern works.
        if layout.ignoredIslands.count < contour.islands.count {
            try requireIslandSupport(pattern: pattern, entry: entry)
        }

        var passes: [SC.ToolpathPass] = []
        var previousZ = 0.0 // top of stock, like `.pocket`: the first layer ramps/helixes down from here
        var lastPlans: [PocketPlan] = []

        for band in layout.bands {

            // Only this band's standing islands, and only now are the ones touching the wall
            // cut out of it: in the layers above its top an island is cut over like any other
            // material.
            var bandPocket = contour
            bandPocket.islands = band.activeIslands.map { contour.islands[$0] }

            var plans: [PocketPlan] = []
            for pocket in mergingTouchingIslands([bandPocket]) {
                plans.append(try planPocket(for: pocket,
                                            tool: tool,
                                            settings: settings,
                                            direction: direction,
                                            pattern: pattern,
                                            entry: entry))
            }
            guard !plans.isEmpty else {
                continue // the islands fill the whole pocket: nothing to cut in these layers
            }

            // `previousZ` runs across bands: the first layer of a band starts its ramp or
            // helix at the floor of the layer above, which is already cleared.
            var bandPasses: [SC.ToolpathPass] = []
            for z in band.layers {
                var waypoints: [SC.Waypoint] = []
                for plan in plans {
                    waypoints.append(contentsOf: pocketPassWaypoints(plan: plan,
                                                                     toolRadius: toolRadius,
                                                                     atZ: z,
                                                                     previousZ: previousZ,
                                                                     settings: settings,
                                                                     entry: entry))
                }
                bandPasses.append(SC.ToolpathPass(passIndex: 0, depthZ: z, waypoints: waypoints))
                previousZ = z
            }

            // Shortcuts between the layers of a band; the last layer of a band, and the move
            // to the next band, always retract fully. With several pieces there is no single
            // region to travel in, so those keep the full retract too.
            if plans.count == 1 {
                applyPocketRetractPolicy(to: &bandPasses, plan: plans[0], pattern: pattern, tool: tool, settings: settings)
            }

            passes.append(contentsOf: bandPasses)
            lastPlans = plans
        }

        guard !passes.isEmpty else {
            throw SC.Error.geometryCollapsed
        }
        for index in passes.indices {
            passes[index].passIndex = index
        }

        // The corners the tool couldn't reach at the floor, where every island stands.
        let corners = lastPlans.flatMap { self.restCorners(in: $0.baseSegments, toolRadius: toolRadius) }

        return SC.OutputToolpath(operation: operation,
                                 tool: tool,
                                 settings: settings,
                                 passes: passes,
                                 restCorners: corners,
                                 warnings: warnings)
    }
}
