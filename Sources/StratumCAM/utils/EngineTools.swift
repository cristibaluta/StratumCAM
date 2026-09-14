//
//  File.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 13.09.2026.
//

import Foundation

struct EngineTools {

    /// Whether `angle` falls within the arc sweep from `start` to `end`, travelling in
    /// the direction `isCCW` says -- all three normalized into the same wraparound-safe
    /// space first, since raw `atan2` results and stored sweep angles can straddle the
    /// -pi/pi or 0/2pi seam independently of each other.
    static func angleWithinSweep(_ angle: Double, start: Double, end: Double, isCCW: Bool) -> Bool {

        let twoPi = 2 * Double.pi

        func normalized(_ a: Double) -> Double {
            let m = a.truncatingRemainder(dividingBy: twoPi)
            return m < 0 ? m + twoPi : m
        }

        let a = normalized(angle)
        let s = normalized(start)
        var e = normalized(end)
        var probe = a

        if isCCW {
            if e < s { e += twoPi }
            if probe < s { probe += twoPi }
            return probe >= s - 1e-9 && probe <= e + 1e-9
        } else {
            if e > s { e -= twoPi }
            if probe > s { probe -= twoPi }
            return probe <= s + 1e-9 && probe >= e - 1e-9
        }
    }

    /// Gives a list of passes
    static func calculateZPasses(targetDepth: Double, stepdown: Double) -> [Double] {
        let absoluteTarget = abs(targetDepth)
        let step = abs(stepdown)
        guard step > 0, absoluteTarget > 0 else {
            return [-absoluteTarget]
        }

        // Number of full-depth passes needed. Dividing doubles can land a hair on either
        // side of a whole number (e.g. 1.0 / 0.1 == 9.999999999999998), so snap to the
        // nearest integer when we're within a tiny tolerance of one before rounding up --
        // otherwise a perfectly even depth/stepdown pair would silently gain an extra
        // pass. Once the count is fixed, each depth is derived by multiplication rather
        // than repeated addition, so there's no accumulated drift across passes either.
        let rawCount = absoluteTarget / step
        let epsilon = 1e-9
        let passCount: Int
        if abs(rawCount.rounded() - rawCount) < epsilon {
            passCount = max(1, Int(rawCount.rounded()))
        } else {
            passCount = max(1, Int(rawCount.rounded(.up)))
        }

        return (0..<passCount).map { i in
            let depth = (i == passCount - 1) ? absoluteTarget : step * Double(i + 1)
            return -depth
        }
    }
}
