//
//  Contour.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import SwiftDXF

extension SC {

    public struct Contour: Sendable {
        
        public struct Chained: Sendable {
            public var entity: DXF.Entity
            public var reversed: Bool

            // The inits are needed because the app using the lib is not able to init otherwise
            public init(entity: DXF.Entity, reversed: Bool) {
                self.entity = entity
                self.reversed = reversed
            }
        }

        public var entities: [Chained]
        public var isClosed: Bool

        public init(entities: [Chained], isClosed: Bool) {
            self.entities = entities
            self.isClosed = isClosed
        }
    }
}
