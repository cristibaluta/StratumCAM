//
//  ThreadDirection.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 14.09.2026.
//

import Foundation

extension SC {

    /// Defines the handedness of a thread being milled.
    public enum ThreadDirection: String, Sendable, Codable, Equatable {

        /// A standard right-hand thread: winds clockwise when viewed from the end
        /// the tool is advancing away from, i.e. the helix advances upward (+Z)
        /// while sweeping counterclockwise when viewed from above.
        ///
        /// - Standard Use: The vast majority of fasteners and tapped/threaded
        ///   features. Default choice unless a left-hand thread is explicitly
        ///   called for.
        case rightHand

        /// A left-hand thread: the mirror image of a right-hand thread -- the
        /// helix advances upward (+Z) while sweeping clockwise when viewed from
        /// above.
        ///
        /// - Standard Use: Applications where a right-hand thread could work
        ///   itself loose under normal rotation, e.g. the left-side pedal of a
        ///   bicycle crank, or some gas-cylinder fittings.
        case leftHand
    }
}
