//
//  CGPoint+Ext.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.11.2026.
//

import Foundation

// TODO: add utests
extension CGPoint {

    func distanceToSegment(_ a: CGPoint, _ b: CGPoint) -> Double {

        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 1e-18 else {
            return hypot(self.x - a.x, self.y - a.y)
        }
        let t = max(0, min(1, ((self.x - a.x) * dx + (self.y - a.y) * dy) / lengthSquared))

        return hypot(self.x - (a.x + t * dx), self.y - (a.y + t * dy))
    }
}
