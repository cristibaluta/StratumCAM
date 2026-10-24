//
//  EntityChainer.swift
//  Stratum CNC
//
//  Created by Cristian Baluta on 08.09.2026.
//

import Foundation

/// Converts a list of `SC.Geometry` to `[SC.Contour]`
public enum EntityChainer {

    public static func chain(_ entities: [SC.Geometry], tolerance: Double = 1e-3) -> [SC.Contour] {

        var remaining = entities.map { (geometry: $0, used: false) }
        var contours: [SC.Contour] = []

        func endpoints(_ e: SC.Geometry) -> (CGPoint, CGPoint)? {
            switch e {
                case let .line(a, b):
                    return (a.cgPoint, b.cgPoint)

                case let .polyline(vertices, _):
                    guard let f = vertices.first, let l = vertices.last else {
                        return nil
                    }
                    return (f.point.cgPoint, l.point.cgPoint)

                case let .arc(center, r, start, end):
                    let s = CGPoint(x: center.x + r*cos(start * .pi/180), y: center.y + r*sin(start * .pi/180))
                    let e2 = CGPoint(x: center.x + r*cos(end * .pi/180), y: center.y + r*sin(end * .pi/180))
                    return (s, e2)

                default: return nil // circles/points/ellipses: standalone
            }
        }

        func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
            hypot(a.x - b.x, a.y - b.y) <= tolerance
        }

        // A polyline flagged closed is a closed contour on its own: its last vertex is not
        // where it started (the closing edge is implicit), so it can't be chained to anything.
        var closedPolylines = Set<Int>()
        for index in remaining.indices {
            if case .polyline(_, true) = remaining[index].geometry {
                closedPolylines.insert(index)
            }
        }

        for startIndex in remaining.indices {
            if closedPolylines.contains(startIndex) {
                contours.append(
                    SC.Contour(entities: [SC.Contour.Chained(geometry: remaining[startIndex].geometry, reversed: false)], isClosed: true)
                )
                remaining[startIndex].used = true
                continue
            }
            guard !remaining[startIndex].used, let (s0, e0) = endpoints(remaining[startIndex].geometry) else {
                continue
            }

            var chain: [SC.Contour.Chained] = [SC.Contour.Chained(geometry: remaining[startIndex].geometry, reversed: false)]
            remaining[startIndex].used = true
            var tail = e0

            var extended = true
            while extended {
                extended = false
                for i in remaining.indices where !remaining[i].used && !closedPolylines.contains(i) {
                    guard let (a, b) = endpoints(remaining[i].geometry) else {
                        continue
                    }
                    if close(tail, a) {
                        chain.append(SC.Contour.Chained(geometry: remaining[i].geometry, reversed: false))
                        remaining[i].used = true
                        tail = b
                        extended = true
                        break
                    } else if close(tail, b) {
                        chain.append(SC.Contour.Chained(geometry: remaining[i].geometry, reversed: true))
                        remaining[i].used = true
                        tail = a
                        extended = true
                        break
                    }
                }
            }

            contours.append(
                SC.Contour(entities: chain, isClosed: close(tail, s0))
            )
        }

        for i in remaining.indices where !remaining[i].used {
            contours.append(
                SC.Contour(entities: [SC.Contour.Chained(geometry: remaining[i].geometry, reversed: false)], isClosed: true)
            )
            remaining[i].used = true
        }

        return contours
    }
}
