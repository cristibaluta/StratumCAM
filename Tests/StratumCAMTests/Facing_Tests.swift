//
//  Facing_Tests.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Testing
import CoreGraphics
import simd
@testable import StratumCAM

// Step 2A.1: facing footprint (`facingArea`) + raster scanline geometry
// (`facingScanlines`). Geometry only -- no waypoints, no wiring into
// `SCEngine.buildToolpath`'s switch yet (that's Step 2A.2).

struct Facing_Tests {

    // MARK: - Footprint

    @Test("Facing area grows the stock rectangle by extensionLength on every side")
    func testFacingAreaExpandsStockByExtensionLength() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 100, height: 50, thickness: 10, origin: .zero)

        let area = engine.facingArea(stock: stock, extensionLength: 5)

        #expect(area.minX == -5, "Test Failed: expected minX grown 5mm past the stock's left edge")
        #expect(area.maxX == 105, "Test Failed: expected maxX grown 5mm past the stock's right edge")
        #expect(area.minY == -5, "Test Failed: expected minY grown 5mm past the stock's bottom edge")
        #expect(area.maxY == 55, "Test Failed: expected maxY grown 5mm past the stock's top edge")
    }

    @Test("Facing area honors a non-zero stock origin")
    func testFacingAreaHonorsStockOrigin() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 40, height: 20, thickness: 6, origin: SIMD3<Double>(10, 20, 0))

        let area = engine.facingArea(stock: stock, extensionLength: 2)

        #expect(area.minX == 8, "Test Failed: expected minX offset by the stock's own origin")
        #expect(area.maxX == 52, "Test Failed: expected maxX offset by the stock's own origin")
        #expect(area.minY == 18, "Test Failed: expected minY offset by the stock's own origin")
        #expect(area.maxY == 42, "Test Failed: expected maxY offset by the stock's own origin")
    }

    @Test("Facing area with zero extensionLength matches the stock rectangle exactly")
    func testFacingAreaWithNoExtension() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 30, height: 15, thickness: 6, origin: .zero)

        let area = engine.facingArea(stock: stock, extensionLength: 0)

        #expect(area.minX == 0 && area.maxX == 30, "Test Failed: expected X bounds to match the stock exactly")
        #expect(area.minY == 0 && area.maxY == 15, "Test Failed: expected Y bounds to match the stock exactly")
    }

    // MARK: - Scanline generation + stepover

    @Test("Facing scanlines cover the footprint with parallel rows spaced by stepover")
    func testFacingScanlinesCoverFootprintWithHonoredStepover() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        // No extension -> footprint is exactly [0,20]x[0,10]. 2mm stepover over a
        // 10mm-tall footprint -> 5 evenly-spaced rows (y=0,2,4,6,8,10).
        let rows = engine.facingScanlines(stock: stock, extensionLength: 0, stepover: 2.0, direction: .climb)

        #expect(rows.count == 6, "Test Failed: expected 6 rows for a 10mm span at 2mm stepover, got \(rows.count)")

        let rowYs = rows.map { $0[0].startPoint.y }
        let expectedYs = [0.0, 2.0, 4.0, 6.0, 8.0, 10.0]
        for (actual, expected) in zip(rowYs, expectedYs) {
            #expect(abs(actual - expected) < 1e-5, "Test Failed: expected row at y=\(expected), got y=\(actual)")
        }

        for row in rows {
            let xs = [row[0].startPoint.x, row[0].endPoint.x].sorted()
            #expect(abs(xs[0] - 0.0) < 1e-5 && abs(xs[1] - 20.0) < 1e-5,
                    "Test Failed: expected every row to span the full footprint width [0,20]")
        }
    }

    @Test("Facing scanlines include extensionLength in both the row span and the row count")
    func testFacingScanlinesHonorExtensionLength() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        // 3mm extension -> footprint [-3,23]x[-3,13], a 16mm-tall span. 4mm stepover
        // -> 4 steps exactly -> 5 rows (y = -3, 1, 5, 9, 13).
        let rows = engine.facingScanlines(stock: stock, extensionLength: 3.0, stepover: 4.0, direction: .climb)

        #expect(rows.count == 5, "Test Failed: expected 5 rows for a 16mm span at 4mm stepover, got \(rows.count)")

        let rowYs = rows.map { $0[0].startPoint.y }
        let expectedYs = [-3.0, 1.0, 5.0, 9.0, 13.0]
        for (actual, expected) in zip(rowYs, expectedYs) {
            #expect(abs(actual - expected) < 1e-5, "Test Failed: expected row at y=\(expected), got y=\(actual)")
        }

        for row in rows {
            let xs = [row[0].startPoint.x, row[0].endPoint.x].sorted()
            #expect(abs(xs[0] - (-3.0)) < 1e-5 && abs(xs[1] - 23.0) < 1e-5,
                    "Test Failed: expected every row to span the extended footprint width [-3,23]")
        }
    }

    // MARK: - Direction

    @Test("Facing scanlines honor climb versus conventional starting direction")
    func testFacingScanlinesHonorDirection() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        let climbRows = engine.facingScanlines(stock: stock, extensionLength: 0, stepover: 5.0, direction: .climb)
        let conventionalRows = engine.facingScanlines(stock: stock, extensionLength: 0, stepover: 5.0, direction: .conventional)

        #expect(climbRows.count == conventionalRows.count,
                "Test Failed: direction should not change how many rows are generated")

        // Climb starts left-to-right; conventional starts right-to-left. Every row
        // still alternates (boustrophedon), so the two sequences are exact mirrors of
        // each other, row for row.
        for (climbRow, conventionalRow) in zip(climbRows, conventionalRows) {
            #expect(climbRow[0].startPoint == conventionalRow[0].endPoint,
                    "Test Failed: expected climb and conventional to traverse each row in opposite directions")
            #expect(climbRow[0].endPoint == conventionalRow[0].startPoint,
                    "Test Failed: expected climb and conventional to traverse each row in opposite directions")
        }

        #expect(climbRows[0][0].startPoint.x < climbRows[0][0].endPoint.x,
                "Test Failed: expected climb's first row to travel left-to-right")
        #expect(conventionalRows[0][0].startPoint.x > conventionalRows[0][0].endPoint.x,
                "Test Failed: expected conventional's first row to travel right-to-left")
    }

    @Test("Facing scanlines alternate direction row to row (boustrophedon)")
    func testFacingScanlinesAlternateDirection() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        let rows = engine.facingScanlines(stock: stock, extensionLength: 0, stepover: 2.5, direction: .climb)

        for (i, row) in rows.enumerated() {
            let travelsLeftToRight = row[0].startPoint.x < row[0].endPoint.x
            #expect(travelsLeftToRight == (i % 2 == 0),
                    "Test Failed: expected row \(i) to alternate direction from its neighbors")
        }
    }

    // MARK: - Fencepost: uneven stepover snaps the last row to the footprint edge

    @Test("Facing scanlines snap the last row to the footprint edge on an unevenly divisible stepover")
    func testFacingScanlinesSnapsLastRowOnUnevenStepover() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        // 10mm span at 3mm stepover doesn't divide evenly (10 / 3 = 3.33), so it
        // rounds up to 4 steps -> 5 rows, with the final gap narrower than the other
        // 3 (each exactly 3mm) -- the same fencepost rule `rasterScanlines` and
        // `calculateZPasses` already apply.
        let rows = engine.facingScanlines(stock: stock, extensionLength: 0, stepover: 3.0, direction: .climb)

        #expect(rows.count == 5, "Test Failed: expected 5 rows (3 even steps + 1 snapped remainder), got \(rows.count)")

        let rowYs = rows.map { $0[0].startPoint.y }
        let expectedYs = [0.0, 3.0, 6.0, 9.0, 10.0]
        for (actual, expected) in zip(rowYs, expectedYs) {
            #expect(abs(actual - expected) < 1e-5, "Test Failed: expected row at y=\(expected), got y=\(actual)")
        }

        let lastGap = rowYs[4] - rowYs[3]
        #expect(lastGap < 3.0 - 1e-5,
                "Test Failed: expected the final row's gap to be narrower than the honored stepover")
    }

    // MARK: - Validation

    @Test("Facing scanlines are empty for a degenerate (zero-area) stock")
    func testFacingScanlinesRequireNonZeroStock() {
        let engine = SCEngine()
        let zeroWidthStock = SC.Stock(width: 0, height: 10, thickness: 6, origin: .zero)
        let zeroHeightStock = SC.Stock(width: 20, height: 0, thickness: 6, origin: .zero)

        #expect(engine.facingScanlines(stock: zeroWidthStock, extensionLength: 0, stepover: 2.0, direction: .climb).isEmpty,
                "Test Failed: a zero-width stock should produce no scanlines")
        #expect(engine.facingScanlines(stock: zeroHeightStock, extensionLength: 0, stepover: 2.0, direction: .climb).isEmpty,
                "Test Failed: a zero-height stock should produce no scanlines")
    }

    @Test("Facing scanlines are empty for a non-positive stepover")
    func testFacingScanlinesRequirePositiveStepover() {
        let engine = SCEngine()
        let stock = SC.Stock(width: 20, height: 10, thickness: 6, origin: .zero)

        #expect(engine.facingScanlines(stock: stock, extensionLength: 0, stepover: 0, direction: .climb).isEmpty,
                "Test Failed: a zero stepover should produce no scanlines")
        #expect(engine.facingScanlines(stock: stock, extensionLength: 0, stepover: -1, direction: .climb).isEmpty,
                "Test Failed: a negative stepover should produce no scanlines")
    }
}
