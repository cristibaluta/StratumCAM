//
//  SIMD+Ext.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 24.10.2026.
//

import Foundation
import simd

extension SIMD2 where Scalar == Double {

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}
