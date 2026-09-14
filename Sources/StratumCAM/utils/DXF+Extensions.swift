//
//  DXF+Extensions.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 14.09.2026.
//

import Foundation
import SwiftDXF

extension DXF.Point {
    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}
