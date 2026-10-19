//
//  CuttingData_Tests.swift
//  StratumCAM
//

import Testing
@testable import StratumCAM

struct CuttingData_Tests {

    @Test("Default stepover is 25% of the tool diameter")
    func testDefaultStepoverIs25Percent() {
        #expect(SC.CuttingData().stepoverPercentage == 0.25)
    }

    @Test("Default stepover spaces concentric rings by a quarter of the tool diameter")
    func testDefaultStepoverSpacesRings() throws {
        let engine = SCEngine()
        let tool = SC.ToolParams(diameter: 6.0)
        let contour = SC.Contour(entities: [
            .init(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(40, 0)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(40, 0), b: SIMD2<Double>(40, 40)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(40, 40), b: SIMD2<Double>(0, 40)), reversed: false),
            .init(geometry: .line(a: SIMD2<Double>(0, 40), b: SIMD2<Double>(0, 0)), reversed: false)
        ], isClosed: true)
        let oriented = contour.linearizedSegments
        let rings = engine.pocketRings(from: oriented, tool: tool, stepoverPercentage: SC.CuttingData().stepoverPercentage)
        #expect(rings.count > 2)
        let outer = rings[0].boundingBox
        let next = rings[1].boundingBox
        #expect(abs((next.minX - outer.minX) - 1.5) < 1e-6)
    }
}
