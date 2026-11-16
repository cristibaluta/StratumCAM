//
//  SCEngine+ContourGaps.swift
//  StratumCAM
//
//  Repairs the contours of a part projected to Z0 before any toolpath is calculated: the
//  projection leaves one outline split over several contours, each ending where a face or a
//  feature is missing. The pieces are chained back together across contours.
//

import Foundation
import CoreGraphics

/// One entity with the points it starts and ends on, in the way it is being walked.
fileprivate struct GapPiece {
    var chained: SC.Contour.Chained
    var start: CGPoint
    var end: CGPoint

    var flipped: GapPiece {
        GapPiece(chained: SC.Contour.Chained(geometry: chained.geometry, reversed: !chained.reversed),
                 start: end,
                 end: start)
    }
}

/// Pieces that touch one after another, coming from the contour at index `source`.
fileprivate struct GapRun {
    var pieces: [GapPiece]
    var source: Int

    var head: CGPoint { pieces[0].start }
    var tail: CGPoint { pieces[pieces.count - 1].end }

    /// The same run walked the other way round.
    var flipped: GapRun {
        GapRun(pieces: pieces.reversed().map { $0.flipped }, source: source)
    }
}

extension SCEngine {

    /// Turns the open contours of a projected part into closed outlines.
    ///
    /// Only the contours that are not closed are treated as pieces of the same outline:
    /// 1. Inside each contour the entities are put in order and orientation (each one is
    ///    turned round when needed), so what is touching forms a run.
    /// 2. Starting from the first run and walking around the outline, wherever the walk ends
    ///    on a free end it continues with the run, from any contour, whose free end is closest.
    ///    A run is flipped as a whole when its far end is the closer one, and joined by a
    ///    straight line.
    /// 3. When the closest free end is further away than the way back to the start, or
    ///    nothing is left, the last point is joined to the start and the outline is closed.
    ///    Runs left over start an outline of their own.
    ///
    /// The contours that make up one outline are replaced by a single closed contour, at
    /// the position of the first of them. Contours already flagged closed are not touched,
    /// and neither are contours with a point marker or an entity that closes on itself
    /// (circle, closed polyline); the engine cuts each of them as its own profile.
    /// Zero-length entities and duplicated lines are dropped.
    func closingGaps(in contours: [SC.Contour], tolerance: Double = 1e-3) -> [SC.Contour] {

        var result: [SC.Contour?] = contours
        var pool: [(index: Int, pieces: [GapPiece])] = []

        for (index, contour) in contours.enumerated() {
            // A contour flagged closed is already a profile of its own: left as it is.
            guard !contour.isClosed, let pieces = gapPieces(of: contour, tolerance: tolerance) else {
                continue
            }
            pool.append((index, pieces))
        }

        if !pool.isEmpty {
            let outlines = joinedOutlines(from: pool.map { (contours[$0.index], $0.pieces) },
                                          consumeAll: false,
                                          tolerance: tolerance)
            for entry in pool {
                result[entry.index] = nil
            }
            for outline in outlines {
                result[pool[outline.first].index] = outline.contour
            }
        }

        return result.compactMap { $0 }
    }

    // MARK: - Pieces

    /// The entities of `contour` as pieces, or `nil` when the contour must be left alone.
    private func gapPieces(of contour: SC.Contour, tolerance: Double) -> [GapPiece]? {

        func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
            hypot(a.x - b.x, a.y - b.y) <= tolerance
        }

        var pieces: [GapPiece] = []
        for chained in contour.entities {
            if case .point = chained.geometry {
                return nil
            }
            let segments = contour.convert(geometry: chained.geometry, reversed: chained.reversed).removingDegenerate
            guard let first = segments.first, let last = segments.last else {
                continue // zero length
            }
            let start = first.startPoint
            let end = last.endPoint
            if close(start, end) {
                return nil // closes on itself
            }
            if case .line = chained.geometry {
                let duplicate = pieces.contains { other in
                    guard case .line = other.chained.geometry else {
                        return false
                    }
                    return (close(other.start, start) && close(other.end, end))
                        || (close(other.start, end) && close(other.end, start))
                }
                if duplicate {
                    continue
                }
            }
            pieces.append(GapPiece(chained: chained, start: start, end: end))
        }
        return pieces.isEmpty ? nil : pieces
    }

    // MARK: - Joining

    /// Chains the contours of `group` into closed outlines. `first` is the index in `group`
    /// of the contour the outline starts on.
    private func joinedOutlines(from group: [(contour: SC.Contour, pieces: [GapPiece])],
                                consumeAll: Bool,
                                tolerance: Double) -> [(first: Int, contour: SC.Contour)] {

        func dist(_ a: CGPoint, _ b: CGPoint) -> Double {
            hypot(a.x - b.x, a.y - b.y)
        }

        func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
            dist(a, b) <= tolerance
        }

        func bridge(from a: CGPoint, to b: CGPoint) -> GapPiece {
            GapPiece(chained: SC.Contour.Chained(geometry: .line(a: SIMD2<Double>(Double(a.x), Double(a.y)),
                                                                 b: SIMD2<Double>(Double(b.x), Double(b.y))),
                                                 reversed: false),
                     start: a,
                     end: b)
        }

        // 1. Runs of touching pieces inside each contour, grown from both ends.
        var runs: [GapRun] = []
        for (source, entry) in group.enumerated() {
            let pieces = entry.pieces
            var used = [Bool](repeating: false, count: pieces.count)
            for seed in pieces.indices where !used[seed] {
                used[seed] = true
                var run = GapRun(pieces: [pieces[seed]], source: source)

                var extended = true
                while extended {
                    extended = false
                    if run.pieces.count > 1, close(run.head, run.tail) {
                        break // the run closes on itself
                    }
                    for i in pieces.indices where !used[i] {
                        let piece = pieces[i]
                        if close(run.tail, piece.start) {
                            run.pieces.append(piece)
                        } else if close(run.tail, piece.end) {
                            run.pieces.append(piece.flipped)
                        } else if close(run.head, piece.end) {
                            run.pieces.insert(piece, at: 0)
                        } else if close(run.head, piece.start) {
                            run.pieces.insert(piece.flipped, at: 0)
                        } else {
                            continue
                        }
                        used[i] = true
                        extended = true
                        break
                    }
                }
                runs.append(run)
            }
        }

        // 2. Walk around, always on to the closest free end among all the runs left.
        var outlines: [(first: Int, contour: SC.Contour)] = []
        var done = [Bool](repeating: false, count: runs.count)

        for seed in runs.indices where !done[seed] {
            done[seed] = true
            var current = runs[seed]
            let start = current.head
            var sources: Set<Int> = [current.source]

            while true {
                var best: (index: Int, flip: Bool, distance: Double)?
                for j in runs.indices where !done[j] {
                    let toHead = dist(current.tail, runs[j].head)
                    let toTail = dist(current.tail, runs[j].tail)
                    let candidate = toHead <= toTail
                        ? (index: j, flip: false, distance: toHead)
                        : (index: j, flip: true, distance: toTail)
                    if best == nil || candidate.distance < best!.distance {
                        best = candidate
                    }
                }
                guard let next = best else {
                    break
                }
                // Closer to go back to the start than on to the next run: this outline is done.
                if !consumeAll, next.distance >= dist(current.tail, start) {
                    break
                }
                done[next.index] = true
                let run = next.flip ? runs[next.index].flipped : runs[next.index]
                current.pieces.append(bridge(from: current.tail, to: run.head))
                current.pieces.append(contentsOf: run.pieces)
                sources.insert(run.source)
            }

            // 3. Back to the start.
            if !close(current.tail, start) {
                current.pieces.append(bridge(from: current.tail, to: start))
            }

            let origin = group[current.source].contour
            let contour = SC.Contour(entities: current.pieces.map { $0.chained },
                                     isClosed: true,
                                     islands: sources.sorted().flatMap { group[$0].contour.islands },
                                     topZ: origin.topZ)
            outlines.append((current.source, contour))
        }
        return outlines
    }
}
