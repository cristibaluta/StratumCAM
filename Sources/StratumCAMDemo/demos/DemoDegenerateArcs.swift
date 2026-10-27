//
//  DemoDegenerateArcs.swift
//  StratumCAM
//

import Foundation
import StratumCAM

class DemoDegenerateArcs: Demo {

    /// A 20x20 square, engraved on the contour, with junk arcs at two of its corners -- the kind
    /// a raster trace or a sloppy CAD export leaves behind:
    /// - at (20, 0) a zero-sweep arc entity (start angle == end angle),
    /// - at (20, 20) a polyline vertex duplicated 1e-7 mm away, carrying a bulge, i.e. a
    ///   micro arc a ten-millionth of a millimetre long.
    ///
    /// An arc whose end point equals its start point is a full circle to a controller, so
    /// without the fix the G-code gets a full-circle G03 at each of those corners. Check the
    /// G-code tab: the toolpath is a plain square and there is no G02/G03 at all.
    func demoSquareWithJunkArcs() -> Demo.DemoResult {
        let tool = SC.ToolParams(diameter: 3.175)
        let cutting = SC.CuttingData(feedRate: 1000.0, plungeRate: 300.0, stepdown: 0.1)
        let settings = SC.MachineSettings(cutting: cutting, safeZ: 5.0, targetDepth: -0.5)

        let contour = SC.Contour(
            entities: [
                SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(0, 0), b: SIMD2<Double>(20, 0)), reversed: false),
                // Zero-sweep arc at (20, 0): radius 5 around (20, 5), 270 degrees to 270 degrees.
                SC.Contour.Chained(geometry: .arc(center: SIMD2<Double>(20, 5), radius: 5, startDeg: 270, endDeg: 270),
                                   reversed: false),
                SC.Contour.Chained(geometry: .polyline(vertices: [.init(SIMD2<Double>(20, 0)),
                                                                .init(SIMD2<Double>(20, 20), bulge: 1),
                                                                .init(SIMD2<Double>(20, 20.0000001))],
                                                     closed: false),
                                   reversed: false),
                SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(20, 20.0000001), b: SIMD2<Double>(0, 20)), reversed: false),
                SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(0, 20), b: SIMD2<Double>(0, 0)), reversed: false)
            ],
            isClosed: true
        )

        return self.run(contour: contour, tool: tool, settings: settings, operation: .engrave())
    }
}
