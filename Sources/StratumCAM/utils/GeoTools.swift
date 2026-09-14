//
//  GeoTools.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 14.09.2026.
//

import Foundation

struct GeoTools {
    public static func lineLineIntersection(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> [CGPoint] {

        let d1x = p2.x - p1.x, d1y = p2.y - p1.y
        let d2x = p4.x - p3.x, d2y = p4.y - p3.y
        let denom = d1x * d2y - d1y * d2x
        guard abs(denom) > 1e-9 else {
            return [] // parallel
        }
        let t = ((p3.x - p1.x) * d2y - (p3.y - p1.y) * d2x) / denom

        return [CGPoint(x: p1.x + t * d1x, y: p1.y + t * d1y)]
    }

    public static func circleLineIntersections(center: CGPoint, radius: Double, p1: CGPoint, p2: CGPoint) -> [CGPoint] {

        let dx = p2.x - p1.x, dy = p2.y - p1.y
        let fx = p1.x - center.x, fy = p1.y - center.y
        let a = dx * dx + dy * dy
        guard a > 1e-12 else {
            return []
        }
        let b = 2 * (fx * dx + fy * dy)
        let c = fx * fx + fy * fy - radius * radius
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else {
            return []
        }
        let sq = discriminant.squareRoot()
        let t1 = (-b - sq) / (2 * a)
        let t2 = (-b + sq) / (2 * a)

        return [
            CGPoint(x: p1.x + t1 * dx, y: p1.y + t1 * dy),
            CGPoint(x: p1.x + t2 * dx, y: p1.y + t2 * dy)
        ]
    }

    public static func circleCircleIntersections(c1: CGPoint, r1: Double, c2: CGPoint, r2: Double) -> [CGPoint] {

        let dx = c2.x - c1.x, dy = c2.y - c1.y
        let d = hypot(dx, dy)
        guard d > 1e-9, d <= r1 + r2 + 1e-6, d >= abs(r1 - r2) - 1e-6 else {
            return []
        }
        let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
        let h = max(0, r1 * r1 - a * a).squareRoot()
        let xm = c1.x + a * dx / d
        let ym = c1.y + a * dy / d

        return [
            CGPoint(x: xm + h * dy / d, y: ym - h * dx / d),
            CGPoint(x: xm - h * dy / d, y: ym + h * dx / d)
        ]
    }
}
