//
//  Drilling.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Testing
import SwiftDXF
import CoreGraphics
@testable import StratumCAM

// Covers point-contour recognition for `.drilling` -- extraction only, no toolpath yet.

struct Drilling_Tests {

    @Test("A single .point entity is recognized as a drill point")
    func testPointEntityIsRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(entity: .point(at: DXF.Point(5, 7), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        let point = engine.drillPoint(for: contour)

        #expect(point != nil, "Test Failed: expected a drill point")
        #expect(abs(point!.x - 5.0) < 1e-9 && abs(point!.y - 7.0) < 1e-9, "Test Failed: drill point XY mismatch")
    }

    @Test("A single closed circle is recognized as a drill point at its center")
    func testClosedCircleIsRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(entity: .circle(center: DXF.Point(3, 4), radius: 2.5, layer: "0", color: 7), reversed: false)
        ], isClosed: true)

        let point = engine.drillPoint(for: contour)

        #expect(point != nil, "Test Failed: expected a drill point")
        #expect(abs(point!.x - 3.0) < 1e-9 && abs(point!.y - 4.0) < 1e-9, "Test Failed: drill point should be the circle's center")
    }

    @Test("A circle marked as not closed is not treated as a drill point")
    func testOpenCircleIsNotRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(entity: .circle(center: DXF.Point(3, 4), radius: 2.5, layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        #expect(engine.drillPoint(for: contour) == nil, "Test Failed: an unclosed circle should not resolve to a drill point")
    }

    @Test("A line is not recognized as a drill point")
    func testLineIsNotRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        #expect(engine.drillPoint(for: contour) == nil, "Test Failed: a line should not resolve to a drill point")
    }

    @Test("A multi-entity contour is not recognized as a drill point")
    func testMultiEntityContourIsNotRecognizedAsDrillPoint() {
        let engine = SCEngine()
        let contour = SC.Contour(entities: [
            .init(entity: .line(a: DXF.Point(0, 0), b: DXF.Point(10, 0), layer: "0", color: 7), reversed: false),
            .init(entity: .point(at: DXF.Point(5, 5), layer: "0", color: 7), reversed: false)
        ], isClosed: false)

        #expect(engine.drillPoint(for: contour) == nil, "Test Failed: a multi-entity contour should not resolve to a single drill point")
    }
}
