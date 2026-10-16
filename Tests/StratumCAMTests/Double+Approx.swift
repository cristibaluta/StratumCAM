//
//  Double+Approx.swift
//  StratumCAM
//
//  Test helper: tolerance-based Double comparison, so tests can write
//  `point.x ~= 3.0` instead of `abs(point.x - 3.0) < 1e-5`.
//

import Foundation

extension Double {

    /// Default absolute tolerance used by `~=`.
    static let approxTolerance = 1e-5

    /// Approximate equality within an absolute tolerance.
    func isApprox(_ other: Double, tolerance: Double = Double.approxTolerance) -> Bool {
        abs(self - other) < tolerance
    }
}

/// `a ~= b` is true when `a` and `b` differ by less than `Double.approxTolerance` (1e-5).
/// For a different tolerance use `a.isApprox(b, tolerance: 1e-3)`.
///
/// Note: this shadows the stdlib pattern-match `~=` for `Double` operands within the test
/// target (e.g. `case 3.0:` in a `switch` on a Double becomes approximate).
func ~= (lhs: Double, rhs: Double) -> Bool {
    lhs.isApprox(rhs)
}
