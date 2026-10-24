//
//  CutSide.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import Foundation

extension SC {

    /// Defines tool center offset relative to selected target geometry.
    public enum CutSide: String, Sendable, Codable, Equatable {

        /// Tool cuts inside the profile, offset inward by cutter radius
        case inside

        /// Tool cuts outside the profile, offset outward by cutter radius.
        case outside

        /// Tool centerline follows selected geometry directly with zero lateral cutter compensation.
        case onContour
    }
}
