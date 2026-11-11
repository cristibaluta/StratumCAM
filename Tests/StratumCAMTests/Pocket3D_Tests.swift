//
//  Pocket3D_Tests.swift
//  StratumCAM
//
//  Phase 1 of PLAN_3D_POCKETING.md: `.pocket3D`, roughing only.
//

import Testing
import CoreGraphics
import simd
@testable import StratumCAM

struct Pocket3D_Tests {

    // MARK: - Fixtures

    private func rectangle(width: Double = 60, height: Double = 36) -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(width, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(width, 0), b: SIMD2<Double>(width, height)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(width, height), b: SIMD2<Double>(0, height)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, height), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true)
    }

    private func circle(x: Double, y: Double, radius: Double, topZ: Double? = nil) -> SC.Contour {
        SC.Contour(entities: [
            .init(geometry: .circle(center: SIMD2<Double>(x, y), radius: radius), reversed: false)
        ], isClosed: true, topZ: topZ)
    }

    // The demo: island A (r 7) at (18, 18) with top -3, island B (r 6) at (42, 18) with top -6.
    private let islandA = (x: 18.0, y: 18.0, radius: 7.0)
    private let islandB = (x: 42.0, y: 18.0, radius: 6.0)
    private let toolDiameter = 6.0

    private func demoShapes(topA: Double? = -3, topB: Double? = -6) -> [SC.Contour] {
        [rectangle(),
         circle(x: islandA.x, y: islandA.y, radius: islandA.radius, topZ: topA),
         circle(x: islandB.x, y: islandB.y, radius: islandB.radius, topZ: topB)]
    }

    private func settings(depth: Double = 8) -> SC.MachineSettings {
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        return SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: depth)
    }

    private let concentric = SC.PocketClearingPattern.concentric(direction: .insideOut)

    private func generate3D(_ shapes: [SC.Contour],
                            depth: Double = 8,
                            pattern: SC.PocketClearingPattern? = nil,
                            entry: SC.EntryStrategy = .plunge,
                            tool: SC.ToolParams? = nil,
                            settings custom: SC.MachineSettings? = nil) throws -> [SC.OutputToolpath] {
        try SCEngine().generateToolpaths(from: shapes,
                                         tool: tool ?? SC.ToolParams(diameter: toolDiameter),
                                         settings: custom ?? settings(depth: depth),
                                         operation: .pocket3D(direction: .climb, pattern: pattern ?? concentric, entry: entry))
    }

    private func generate2D(_ shapes: [SC.Contour],
                            depth: Double = 8,
                            pattern: SC.PocketClearingPattern? = nil,
                            entry: SC.EntryStrategy = .plunge) throws -> [SC.OutputToolpath] {
        try SCEngine().generateToolpaths(from: shapes,
                                         tool: SC.ToolParams(diameter: toolDiameter),
                                         settings: settings(depth: depth),
                                         operation: .pocket(direction: .climb, pattern: pattern ?? concentric, entry: entry))
    }

    /// Same shapes with every `topZ` removed.
    private func withoutHeights(_ shapes: [SC.Contour]) -> [SC.Contour] {
        shapes.map { shape in
            var copy = shape
            copy.topZ = nil
            return copy
        }
    }

    // MARK: - 1. Layers

    @Test("Layers land exactly on every island top, in a table of cases")
    func testLayeredZPasses() {
        func layers(_ depth: Double, _ stepdown: Double, _ breakpoints: [Double]) -> [Double] {
            EngineTools.calculateLayeredZPasses(targetDepth: depth, stepdown: stepdown, breakpoints: breakpoints)
        }
        func matches(_ actual: [Double], _ expected: [Double]) -> Bool {
            actual.count == expected.count && zip(actual, expected).allSatisfy { $0.isApprox($1) }
        }

        // The demo: floor -8, tops -3 and -6.
        #expect(matches(layers(8, 1, [-3, -6]), [-1, -2, -3, -4, -5, -6, -7, -8]))

        // A top that is not a multiple of the stepdown: each stretch is cut in full stepdowns
        // and the stretch's remainder, so the layer still ends on the top.
        #expect(matches(layers(6, 2, [-3]), [-2, -3, -5, -6]))

        // A top already on the grid adds no layer.
        #expect(matches(layers(4, 1, [-2]), [-1, -2, -3, -4]))

        // Two tops 0.05 apart: a thin layer between them, as the plan says it is correct but wasteful.
        #expect(matches(layers(4, 1, [-2, -2.05]), [-1, -2, -2.05, -3.05, -4]))

        // Tops outside the cut, or on its ends, and duplicates change nothing.
        #expect(matches(layers(4, 1, [0, 3, -4, -10, -2, -2 - 1e-9]), [-1, -2, -3, -4]))

        // Without a breakpoint it is the ordinary grid.
        #expect(layers(5, 1.5, []) == EngineTools.calculateZPasses(targetDepth: 5, stepdown: 1.5))
        // Sign of the depth doesn't matter, as everywhere else.
        #expect(layers(-8, 1, [-3]) == layers(8, 1, [-3]))
    }

    // MARK: - 2/3. Active islands and bands

    @Test("The demo splits into three bands: no island, A, then A and B")
    func testBandsOfTheDemo() {
        let layout = SCEngine().pocket3DLayout(islandTops: [-3, -6], targetDepth: 8, stepdown: 1)

        #expect(layout.bands == [
            SCEngine.Pocket3DBand(layers: [-1, -2, -3], activeIslands: []),
            SCEngine.Pocket3DBand(layers: [-4, -5, -6], activeIslands: [0]),
            SCEngine.Pocket3DBand(layers: [-7, -8], activeIslands: [0, 1])
        ])
        #expect(layout.ignoredIslands.isEmpty)
    }

    @Test("An island is in the way of the layer after the one that ends on its top, not of that one")
    func testActiveSetRule() {
        let layout = SCEngine().pocket3DLayout(islandTops: [-3], targetDepth: 6, stepdown: 1)
        let byLayer = Dictionary(uniqueKeysWithValues: layout.bands.flatMap { band in
            band.layers.map { ($0, band.activeIslands) }
        })
        #expect(byLayer[-3] == [])
        #expect(byLayer[-4] == [0])
        #expect(byLayer[-2] == [])
    }

    @Test("Bands = distinct island tops + 1; islands with the same top share a band")
    func testBandCount() {
        let engine = SCEngine()
        #expect(engine.pocket3DLayout(islandTops: [], targetDepth: 8, stepdown: 1).bands.count == 1)
        #expect(engine.pocket3DLayout(islandTops: [-3], targetDepth: 8, stepdown: 1).bands.count == 2)
        #expect(engine.pocket3DLayout(islandTops: [-3, -6], targetDepth: 8, stepdown: 1).bands.count == 3)
        // Two islands with the same top (and the order they are given in) change nothing.
        #expect(engine.pocket3DLayout(islandTops: [-3, -3, -6], targetDepth: 8, stepdown: 1).bands.count == 3)
        #expect(engine.pocket3DLayout(islandTops: [-6, -3, -3], targetDepth: 8, stepdown: 1).bands.count == 3)
    }

    @Test("A boss (nil, zero or above the stock) is in the way of every layer and adds no breakpoint")
    func testBossInLayout() {
        let engine = SCEngine()
        let reference = engine.pocket3DLayout(islandTops: [-3], targetDepth: 8, stepdown: 1)
        let withBosses = engine.pocket3DLayout(islandTops: [nil, 5, 0, -3], targetDepth: 8, stepdown: 1)

        #expect(withBosses.layers == reference.layers)
        #expect(withBosses.bands.map { $0.layers } == reference.bands.map { $0.layers })
        #expect(withBosses.bands.map { $0.activeIslands } == [[0, 1, 2], [0, 1, 2, 3]])

        // topZ = 0 and topZ = nil and topZ > 0 are the same boss.
        let asZero = engine.pocket3DLayout(islandTops: [0, 0, 0], targetDepth: 8, stepdown: 1)
        let asOthers = engine.pocket3DLayout(islandTops: [nil, 5, 0], targetDepth: 8, stepdown: 1)
        #expect(asZero == asOthers)
        #expect(asZero.bands.count == 1)
        #expect(asZero.bands[0].activeIslands == [0, 1, 2])
    }

    @Test("An island whose top is at or below the floor never stands")
    func testIgnoredIslandsInLayout() {
        let layout = SCEngine().pocket3DLayout(islandTops: [-8, -10, -3], targetDepth: 8, stepdown: 1)
        #expect(layout.ignoredIslands == [0, 1])
        #expect(layout.bands.flatMap { $0.activeIslands }.allSatisfy { $0 == 2 })
        // The ignored ones add no breakpoint: only island 2 splits the layers.
        #expect(layout.bands.count == 2)
    }

    // MARK: - 4. Regression: no heights = `.pocket`

    @Test("Without any topZ, .pocket3D gives the same passes as .pocket",
          arguments: [
            (SC.PocketClearingPattern.concentric(direction: .insideOut), SC.EntryStrategy.plunge),
            (SC.PocketClearingPattern.concentric(direction: .outsideIn), SC.EntryStrategy.ramp(angleDegrees: 3)),
            (SC.PocketClearingPattern.adaptive(settings: .init(optimalLoad: 1.2)), SC.EntryStrategy.helix(rampAngleDegrees: 3))
          ])
    func testNoHeightsMatchesPocket(pattern: SC.PocketClearingPattern, entry: SC.EntryStrategy) throws {
        let shapes = withoutHeights(demoShapes())

        let flat = try generate2D(shapes, depth: 4, pattern: pattern, entry: entry)
        let layered = try generate3D(shapes, depth: 4, pattern: pattern, entry: entry)

        #expect(flat.count == 1)
        #expect(layered.count == 1)
        #expect(layered[0].passes == flat[0].passes)
        #expect(layered[0].warnings.isEmpty)
    }

    @Test("Without islands, .pocket3D gives the same passes as .pocket, for every pattern")
    func testNoIslandsMatchesPocketForEveryPattern() throws {
        let patterns: [SC.PocketClearingPattern] = [
            .offset,
            .concentric(direction: .outsideIn),
            .raster,
            .spiral(direction: .insideOut),
            .trochoidal(settings: .init(radialEngagement: 0.3, loopRadius: 1.0)),
            .adaptive(settings: .init(optimalLoad: 1.2))
        ]
        for pattern in patterns {
            let flat = try generate2D([rectangle()], depth: 3, pattern: pattern)
            let layered = try generate3D([rectangle()], depth: 3, pattern: pattern)
            #expect(layered[0].passes == flat[0].passes, "pattern \(pattern)")
        }
    }

    // MARK: - Pass shape

    @Test("Layers run top to bottom with consecutive pass indices, one toolpath for the pocket")
    func testPassStructure() throws {
        let result = try generate3D(demoShapes())

        // The islands are consumed, not machined as pockets of their own.
        #expect(result.count == 1)
        let passes = result[0].passes
        #expect(passes.count == 8)
        #expect(passes.map { $0.passIndex } == Array(0..<8))
        for (pass, expected) in zip(passes, [-1.0, -2, -3, -4, -5, -6, -7, -8]) {
            #expect(pass.depthZ.isApprox(expected))
        }
        // Every layer cuts at its own depth.
        for pass in passes {
            let cutZs = pass.waypoints.filter { $0.motion != .rapid }.map { $0.position.z }
            #expect(cutZs.allSatisfy { $0.isApprox(pass.depthZ) })
        }
    }

    @Test("Each band is the 2D pocket around the islands that stand there")
    func testBandsMatchPocketsWithThoseIslands() throws {
        let passes = try generate3D(demoShapes())[0].passes

        let rect = rectangle()
        let a = circle(x: islandA.x, y: islandA.y, radius: islandA.radius)
        let b = circle(x: islandB.x, y: islandB.y, radius: islandB.radius)

        // Layers -1..-3: a plain rectangle, cut over both islands.
        let plain = try generate2D([rect], depth: 3)[0].passes
        #expect(Array(passes[0...2]) == plain)

        // Layers -4..-6: around A.
        let aroundA = try generate2D([rect, a], depth: 6)[0].passes
        #expect(Array(passes[3...5]) == Array(aroundA[3...5]))

        // Layers -7..-8: around A and B.
        let aroundBoth = try generate2D([rect, a, b], depth: 8)[0].passes
        #expect(Array(passes[6...7]) == Array(aroundBoth[6...7]))
    }

    // MARK: - 6. No gouging

    @Test("Below an island's top the cut stays out of its keep-out zone; above it, it cuts across")
    func testNoGouging() throws {
        let passes = try generate3D(demoShapes())[0].passes
        let toolRadius = toolDiameter / 2.0

        func cutPoints(_ pass: SC.ToolpathPass) -> [SIMD3<Double>] {
            pass.waypoints.filter { $0.motion != .rapid }.map { $0.position }
        }
        func distance(_ p: SIMD3<Double>, _ island: (x: Double, y: Double, radius: Double)) -> Double {
            hypot(p.x - island.x, p.y - island.y)
        }

        for pass in passes {
            for (island, top) in [(islandA, -3.0), (islandB, -6.0)] where pass.depthZ < top - 1e-9 {
                for p in cutPoints(pass) {
                    #expect(distance(p, island) >= island.radius + toolRadius - 1e-6,
                            "layer \(pass.depthZ) cuts into the island with top \(top) at \(p)")
                }
            }
        }

        // The layer that ends on A's top is not blocked by A: it is the plain rectangle again
        // (`testBandsMatchPocketsWithThoseIslands` compares it with the 2D pocket).
        #expect(passes[2].depthZ.isApprox(-3))
    }

    // MARK: - 7. Exact tops

    @Test("There is a pass exactly on the top of every island inside the cut")
    func testExactTops() throws {
        let passes = try generate3D(demoShapes(topA: -2.5, topB: -5.25))[0].passes
        #expect(passes.contains { $0.depthZ == -2.5 })
        #expect(passes.contains { $0.depthZ == -5.25 })
        #expect(passes.last?.depthZ == -8)
        #expect(passes.allSatisfy { $0.depthZ >= -8 })

        // No layer is thicker than the stepdown.
        var previous = 0.0
        for pass in passes {
            #expect(previous - pass.depthZ <= 1.0 + 1e-9)
            previous = pass.depthZ
        }
    }

    // MARK: - 8. Validation and warnings

    @Test("Nested islands are rejected, from a flat list and set by hand")
    func testNestedIslandsRejected() throws {
        let nested = [rectangle(),
                      circle(x: 30, y: 18, radius: 14, topZ: -3),
                      circle(x: 30, y: 18, radius: 5, topZ: -6)]
        #expect(throws: SC.Error.invalidParameter("nested islands are not supported")) {
            try generate3D(nested)
        }

        var island = circle(x: 30, y: 18, radius: 14, topZ: -3)
        island.islands = [circle(x: 30, y: 18, radius: 5, topZ: -6)]
        var pocket = rectangle()
        pocket.islands = [island]
        #expect(throws: SC.Error.invalidParameter("nested islands are not supported")) {
            try generate3D([pocket])
        }
    }

    @Test("An island too close to the wall is an error only where it stands")
    func testIslandTooCloseToWall() throws {
        // A 4 mm island 2 mm from the wall leaves less than the 6 mm tool between them.
        let close = [rectangle(), circle(x: 5, y: 18, radius: 2, topZ: -3)]
        #expect(throws: SC.Error.self) { try generate3D(close) }

        // The same island below the floor never stands: no error, just the plain pocket.
        let belowFloor = [rectangle(), circle(x: 5, y: 18, radius: 2, topZ: -10)]
        let result = try generate3D(belowFloor, depth: 4)
        let plain = try generate2D([rectangle()], depth: 4)
        #expect(result[0].passes == plain[0].passes)
    }

    @Test("An island below the floor is ignored with a warning")
    func testIslandBelowFloorWarns() throws {
        let result = try generate3D(demoShapes(topA: -3, topB: -10))[0]
        #expect(result.warnings.contains(.islandBelowFloor(topZ: -10, floorZ: -8)))

        // Layers below -3 go around A only, as if B had not been drawn.
        let onlyA = try generate3D([rectangle(), circle(x: islandA.x, y: islandA.y, radius: islandA.radius, topZ: -3)])[0]
        #expect(result.passes == onlyA.passes)
    }

    @Test("A pocket deeper than the flutes warns")
    func testFluteLengthWarning() throws {
        let shortTool = SC.ToolParams(diameter: toolDiameter, fluteLength: 5)
        let tooShort = try generate3D(demoShapes(), tool: shortTool)
        #expect(tooShort[0].warnings.contains(.depthExceedsFluteLength(depth: 8, fluteLength: 5)))

        let fine = try generate3D(demoShapes())
        #expect(fine[0].warnings.isEmpty)
    }

    @Test("Stock to leave and a finishing pass are refused in phase 1")
    func testAllowanceRefused() throws {
        var withAllowance = settings()
        withAllowance.allowance = 0.2
        #expect(throws: SC.Error.invalidParameter("allowance")) {
            try generate3D(demoShapes(), settings: withAllowance)
        }

        var withFinishing = settings()
        withFinishing.finishingPass = true
        #expect(throws: SC.Error.invalidParameter("allowance")) {
            try generate3D(demoShapes(), settings: withFinishing)
        }
    }

    // MARK: - 9. Bosses

    @Test("A boss (nil or above the stock) is avoided in every layer, same as topZ = 0")
    func testBossIsAvoidedEverywhere() throws {
        let reference = try generate3D([rectangle(), circle(x: islandA.x, y: islandA.y, radius: islandA.radius, topZ: 0)], depth: 3)[0]
        let toolRadius = toolDiameter / 2.0

        for top in [nil, 5.0, 0.0] as [Double?] {
            let result = try generate3D([rectangle(), circle(x: islandA.x, y: islandA.y, radius: islandA.radius, topZ: top)], depth: 3)[0]
            #expect(result.passes == reference.passes)
            #expect(result.passes.count == 3) // no breakpoint, the ordinary grid
            for pass in result.passes {
                for w in pass.waypoints where w.motion != .rapid {
                    #expect(hypot(w.position.x - islandA.x, w.position.y - islandA.y) >= islandA.radius + toolRadius - 1e-6)
                }
            }
        }
    }

    // MARK: - 10. Patterns

    @Test("Patterns that can't cut around islands throw when one stands, and work when none does")
    func testPatternsAndIslands() throws {
        let patterns: [SC.PocketClearingPattern] = [
            .offset,
            .raster,
            .spiral(direction: .insideOut),
            .trochoidal(settings: .init(radialEngagement: 0.3, loopRadius: 1.0))
        ]
        let standing = [rectangle(), circle(x: islandA.x, y: islandA.y, radius: islandA.radius, topZ: -3)]
        let belowFloor = [rectangle(), circle(x: islandA.x, y: islandA.y, radius: islandA.radius, topZ: -10)]

        for pattern in patterns {
            // Up front, before any layer is built: even though the layers above the top have no island.
            #expect(throws: SC.Error.invalidParameter("islands are only supported by the .concentric and .adaptive patterns")) {
                try generate3D(standing, depth: 4, pattern: pattern)
            }
            let ignoredIsland = try generate3D(belowFloor, depth: 4, pattern: pattern)
            #expect(!ignoredIsland[0].passes.isEmpty, "pattern \(pattern)")
            let noIsland = try generate3D([rectangle()], depth: 4, pattern: pattern)
            #expect(!noIsland[0].passes.isEmpty, "pattern \(pattern)")
        }
    }

    @Test("Concentric with a helix throws only when an island stands")
    func testHelixAndIslands() throws {
        let helix = SC.EntryStrategy.helix(rampAngleDegrees: 3)
        let standing = [rectangle(), circle(x: islandA.x, y: islandA.y, radius: islandA.radius, topZ: -3)]
        let belowFloor = [rectangle(), circle(x: islandA.x, y: islandA.y, radius: islandA.radius, topZ: -10)]

        #expect(throws: SC.Error.invalidParameter("islands support plunge and ramp entries only")) {
            try generate3D(standing, depth: 4, entry: helix)
        }
        let ignoredIsland = try generate3D(belowFloor, depth: 4, entry: helix)
        #expect(!ignoredIsland[0].passes.isEmpty)
        let noIsland = try generate3D([rectangle()], depth: 4, entry: helix)
        #expect(!noIsland[0].passes.isEmpty)
    }

    // MARK: - Operation description

    @Test("The operation describes itself like .pocket, except for the stock to leave")
    func testRequirements() {
        let operation = SC.MachiningOperation.pocket3D(direction: .climb, pattern: .offset, entry: .plunge)
        let pocket = SC.MachiningOperation.pocket(direction: .climb, pattern: .offset, entry: .plunge)

        #expect(operation.kind == .pocket3D)
        #expect(SC.MachiningOperation.Kind.allCases.contains(.pocket3D))

        var expected = pocket.requirements
        expected.usesAllowance = false
        #expect(operation.requirements == expected)
        #expect(operation.requirements.pocketPatterns == SC.PocketClearingPattern.defaults)

        var changed = operation
        changed.direction = .conventional
        changed.entry = .ramp(angleDegrees: 3)
        #expect(changed == .pocket3D(direction: .conventional, pattern: .offset, entry: .ramp(angleDegrees: 3)))
        #expect(changed.direction == .conventional)
        #expect(changed.entry == .ramp(angleDegrees: 3))

        #expect(throws: SC.Error.invalidParameter("pattern.adaptive.optimalLoad")) {
            try SC.MachiningOperation.pocket3D(direction: .climb,
                                               pattern: .adaptive(settings: .init(optimalLoad: 0)),
                                               entry: .plunge).validate(tool: SC.ToolParams())
        }
    }
}
