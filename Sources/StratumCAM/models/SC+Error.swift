//
//  per.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 15.09.2026.
//


//
//  Error.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 15.09.2026.
//

import Foundation

extension SC {

    /// Errors thrown by `SCEngine` when a toolpath genuinely can't be built for the
    /// given input -- as opposed to a toolpath that's legitimately empty by design
    /// (e.g. a DXF `.text` entity, which is never machinable and isn't an error, or
    /// an operation with no lead-out configured). Cases below are grouped by what
    /// went wrong, not by which `SCEngine+*.swift` file raised them, since several
    /// files hit the same underlying problem (a missing drill point, a tool that
    /// doesn't fit) for their own operation.
    ///
    /// Single shared type by design (Step 6.1) -- not one nested enum per operation --
    /// so callers only ever need to switch on one `Error` type regardless of which
    /// `generateToolpaths` overload they called.
    public enum Error: Swift.Error, Sendable, Equatable {

        /// The requested operation needs a closed contour (e.g. `.pocket`), but the
        /// contour passed in isn't closed.
        case contourNotClosed

        /// The contour has no usable geometry for the requested operation -- e.g. it
        /// linearizes to zero segments, or (thread milling) isn't the single closed
        /// circle the operation expects.
        case invalidContour

        /// A point-based operation (drilling, boring, counterbore) needs a contour
        /// with a single identifiable drill point (a closed circle), but none was
        /// found.
        case missingDrillPoint

        /// The tool can't physically perform the requested cut -- e.g. its diameter
        /// doesn't fit inside a requested counterbore/thread diameter, or it's the
        /// wrong kind of tool for the operation (a chamfer without a V-bit angle).
        case toolIncompatible

        /// A parameter on the operation is out of the range the operation needs to
        /// do anything meaningful (e.g. zero radial passes, zero pitch). The
        /// associated string names the parameter for the caller/log, not for
        /// switching on -- don't pattern-match its contents.
        case invalidParameter(String)

        /// The engine's own geometry computation (offsetting, ring-stacking, scanline
        /// generation) produced nothing usable for otherwise-valid input -- e.g. a
        /// tool radius that collapses every offset ring, or a boundary whose span
        /// rounds to zero. Distinct from `invalidContour`: the input passed
        /// validation, the algorithm just had nothing left to build from.
        case geometryCollapsed

        /// The stock's dimensions (or the facing area derived from them) aren't
        /// usable for facing -- zero width/height, or a stepover that doesn't fit.
        case invalidStock

        /// The operation passed to a per-contour `generateToolpaths` call doesn't
        /// support per-contour dispatch -- currently just `.facing`, which needs
        /// `generateToolpaths(from: [SC.FacingOperation])` instead.
        case unsupportedOperation(MachiningOperation)
    }
}