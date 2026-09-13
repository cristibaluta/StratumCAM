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
}
