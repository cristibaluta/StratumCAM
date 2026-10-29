//
//  DemoRestMachining.swift
//  StratumCAM
//
//  Shows what a pocket's tool couldn't reach (filled triangles) and the smaller tool's
//  rest pass that cuts it.
//

import Foundation
import MetalKit
import simd
import StratumCAM

class DemoRestMachining: Demo {

    // MARK: - Fixtures

    /// A closed polygon from its corner points, as straight lines.
    private func polygonContour(_ points: [(Double, Double)]) -> SC.Contour {
        let entities = points.indices.map { i -> SC.Contour.Chained in
            let a = points[i]
            let b = points[(i + 1) % points.count]
            return SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(a.0, a.1), b: SIMD2<Double>(b.0, b.1)),
                                      reversed: false)
        }
        return SC.Contour(entities: entities, isClosed: true)
    }

    // MARK: - Demos

    /// 40x24 rectangle: a 6 mm tool leaves a rounded sliver in each corner, a 2 mm tool takes it.
    func demoRectangle() -> Demo.DemoResult {
        demo(contour: polygonContour([(0, 0), (40, 0), (40, 24), (0, 24)]), bigDiameter: 6, smallDiameter: 2)
    }

    /// The square from the plan: 20x20, 6 mm then 2 mm.
    func demoSquare() -> Demo.DemoResult {
        demo(contour: polygonContour([(0, 0), (20, 0), (20, 20), (0, 20)]), bigDiameter: 6, smallDiameter: 2)
    }

    /// An L: five convex corners get a rest area, the inside (reflex) corner doesn't.
    func demoLShape() -> Demo.DemoResult {
        demo(contour: polygonContour([(0, 0), (40, 0), (40, 16), (16, 16), (16, 40), (0, 40)]),
             bigDiameter: 6,
             smallDiameter: 2)
    }

    /// A sharp triangle: acute corners leave the most material.
    func demoTriangle() -> Demo.DemoResult {
        demo(contour: polygonContour([(0, 0), (50, 0), (25, 36)]), bigDiameter: 6, smallDiameter: 2)
    }

    // MARK: - Building the scene

    /// The pocket with the large tool, the rest areas it leaves (filled), and the rest pass with
    /// the small tool. The rest pass is the scrubbable toolpath; the pocket is drawn dim.
    private func demo(contour: SC.Contour, bigDiameter: Double, smallDiameter: Double) -> Demo.DemoResult {

        let bigTool = SC.ToolParams(diameter: bigDiameter)
        let smallTool = SC.ToolParams(diameter: smallDiameter)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 1.0, stepoverPercentage: 0.4)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -3.0)
        let operation: SC.MachiningOperation = .pocket(direction: .climb, pattern: .offset, entry: .plunge)

        // The pocket, drawn by the shared runner (stock, dashed outline, toolpath).
        let pocket = run(contour: contour, tool: bigTool, settings: settings, operation: operation)

        var corners: [SC.RestCorner] = []
        var restOutputs: [SC.OutputToolpath] = []
        do {
            let pocketOutputs = try engine.generateToolpaths(from: [contour], tool: bigTool, settings: settings, operation: operation)
            corners = pocketOutputs.flatMap(\.restCorners)
            restOutputs = try engine.generateRestToolpaths(corners: corners, tool: smallTool, settings: settings)
        } catch {
            print("rest machining failed: \(error)")
        }

        var restPoints: [SIMD3<Float>] = []
        for output in restOutputs {
            for pass in output.passes {
                restPoints.append(contentsOf: tessellateForRender(pass.waypoints))
            }
        }

        // Order matters (no depth test): fill first, outlines and toolpaths over it. The last
        // batch must be the scrubbable toolpath, which the UI redraws itself.
        var batches = Array(pocket.batches.dropLast())
        if let fill = restAreasBatch(corners: corners, color: SIMD4<Float>(1.0, 0.25, 0.75, 0.9)) {
            batches.append(fill)
        }
        if let outline = restAreasOutlineBatch(corners: corners, color: SIMD4<Float>(1.0, 0.6, 0.9, 1.0)) {
            batches.append(outline)
        }
        if let dimPocket = renderBatch(forPoints: pocket.toolpathPoints, color: SIMD4<Float>(0.45, 0.4, 0.2, 1.0)) {
            batches.append(dimPocket)
        }
        if let restBatch = renderBatch(forPoints: restPoints, color: SIMD4<Float>(1.0, 0.8, 0.0, 1.0)) {
            batches.append(restBatch)
        }

        let gcode = gcodeEngine.generateGCode(from: restOutputs, settings: settings)
        return DemoResult(batches: batches, gcode: gcode, toolpathPoints: restPoints, tool: smallTool)
    }

    // MARK: - Rest areas as geometry

    /// One closed ring of points per corner: the two walls and the tool-circle arc (or the chord
    /// that replaces it on a short wall), the arc sampled into short steps.
    static func ringPoints(of corner: SC.RestCorner, arcSteps: Int = 24) -> [SIMD2<Float>] {
        var ring: [SIMD2<Float>] = []

        for segment in corner.region {
            switch segment {
                case .line(let start, _):
                    ring.append(SIMD2<Float>(Float(start.x), Float(start.y)))

                case .arc(let center, let radius, let startAngle, let endAngle, let isCCW):
                    var sweep = (isCCW ? endAngle - startAngle : startAngle - endAngle)
                        .truncatingRemainder(dividingBy: 2 * .pi)
                    if sweep < 0 {
                        sweep += 2 * .pi
                    }
                    let direction: Double = isCCW ? 1 : -1
                    for i in 0...arcSteps {
                        let angle = startAngle + direction * sweep * Double(i) / Double(arcSteps)
                        ring.append(SIMD2<Float>(Float(center.x + radius * cos(angle)),
                                                 Float(center.y + radius * sin(angle))))
                    }
            }
        }
        return ring
    }

    /// Filled triangles covering every rest area: a fan from the sharp corner over the ring, which
    /// the corner sees completely (walls straight, arc bulging away from it).
    static func restAreaTriangles(corners: [SC.RestCorner], z: Float = 0.02, color: SIMD4<Float>) -> [RenderVertex] {
        var vertices: [RenderVertex] = []
        for corner in corners {
            let ring = ringPoints(of: corner)
            let apex = SIMD3<Float>(Float(corner.corner.x), Float(corner.corner.y), z)
            for i in 0..<ring.count {
                let a = ring[i]
                let b = ring[(i + 1) % ring.count]
                vertices.append(RenderVertex(position: apex, color: color, dist: 0))
                vertices.append(RenderVertex(position: SIMD3<Float>(a.x, a.y, z), color: color, dist: 0))
                vertices.append(RenderVertex(position: SIMD3<Float>(b.x, b.y, z), color: color, dist: 0))
            }
        }
        return vertices
    }

    private func restAreasBatch(corners: [SC.RestCorner], color: SIMD4<Float>) -> RenderBatch? {
        let vertices = DemoRestMachining.restAreaTriangles(corners: corners, color: color)
        guard !vertices.isEmpty,
              let buffer = device.makeBuffer(bytes: vertices,
                                             length: vertices.count * MemoryLayout<RenderVertex>.stride,
                                             options: .storageModeShared) else {
            return nil
        }
        return RenderBatch(vertexBuffer: buffer, vertexCount: vertices.count, primitiveType: .triangle)
    }

    private func restAreasOutlineBatch(corners: [SC.RestCorner], color: SIMD4<Float>) -> RenderBatch? {
        var vertices: [RenderVertex] = []
        for corner in corners {
            let ring = DemoRestMachining.ringPoints(of: corner)
            for i in 0..<ring.count {
                let a = ring[i]
                let b = ring[(i + 1) % ring.count]
                vertices.append(RenderVertex(position: SIMD3<Float>(a.x, a.y, 0.03), color: color, dist: 0))
                vertices.append(RenderVertex(position: SIMD3<Float>(b.x, b.y, 0.03), color: color, dist: 0))
            }
        }
        guard !vertices.isEmpty,
              let buffer = device.makeBuffer(bytes: vertices,
                                             length: vertices.count * MemoryLayout<RenderVertex>.stride,
                                             options: .storageModeShared) else {
            return nil
        }
        return RenderBatch(vertexBuffer: buffer, vertexCount: vertices.count, primitiveType: .line)
    }
}
