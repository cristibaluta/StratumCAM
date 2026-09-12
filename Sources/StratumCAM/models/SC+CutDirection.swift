//
//  CutDirection.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    /// Defines the relative direction between cutter rotation and tool feed.
    public enum CutDirection: String, Sendable, Codable, Equatable {

        /// Cutter rotates WITH the direction of feed (thick chip to thin chip).
        ///
        /// - Real-World Impact: Pushes material down into the table, reduces tool heat,
        ///   and produces superior surface finish.
        /// - Standard Use: Default choice for modern CNC machines, finishing passes,
        ///   and aluminum/non-ferrous metals.
        case climb

        /// Cutter rotates AGAINST the direction of feed (thin chip to thick chip).
        ///
        /// - Real-World Impact: Lifts material upward, causes higher tool friction/heat,
        ///   but prevents tool "pull-in" on flexible or high-backlash machines.
        /// - Standard Use: Used on older or desktop machines with high backlash, or for
        ///   cutting through tough outer crusts (castings, scale).
        case conventional
    }
}
