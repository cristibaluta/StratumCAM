import Testing
import StratumCAM
import StratumCAMDXF
import SwiftDXF

struct DXFAdapter_Tests {

    @Test("Line, arc and circle convert to SC.Geometry")
    func testBasicConversion() {
        let line = SC.Geometry(dxf: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 5), layer: "0", color: 7))
        #expect(line == .line(a: SIMD2(0, 0), b: SIMD2(10, 5)))

        let arc = SC.Geometry(dxf: .arc(center: DXF.Point(1, 2), radius: 3, startDeg: 0, endDeg: 90, layer: "0", color: 7))
        #expect(arc == .arc(center: SIMD2(1, 2), radius: 3, startDeg: 0, endDeg: 90))

        let circle = SC.Geometry(dxf: .circle(center: DXF.Point(4, 5), radius: 6, layer: "0", color: 7))
        #expect(circle == .circle(center: SIMD2(4, 5), radius: 6))
    }

    @Test("Text is not machinable and converts to nil")
    func testTextSkipped() {
        let text = SC.Geometry(dxf: .text(at: DXF.Point(0, 0), height: 1, rotationDeg: 0, string: "x", layer: "0", color: 7))
        #expect(text == nil)
    }

    @Test("Chaining DXF lines produces one closed contour")
    func testChainDXF() {
        let entities: [DXF.Entity] = [
            .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7),
            .line(a: DXF.Point(10, 0), b: DXF.Point(10, 10), layer: "0", color: 7),
            .line(a: DXF.Point(10, 10), b: DXF.Point(0, 0), layer: "0", color: 7)
        ]
        let contours = EntityChainer.chain(entities)
        #expect(contours.count == 1)
        #expect(contours[0].isClosed)
    }
}
