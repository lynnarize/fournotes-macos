import Foundation

// `Int(someDouble)` traps on NaN, on infinity, and on anything outside Int's
// range. Every amount in this app arrives from typed text or from a model, so
// none of those are hypothetical: twenty digits in an amount field is enough to
// overflow a Double to a value that traps on conversion.

extension Int {
    /// A conversion that cannot trap. NaN becomes 0; values beyond Int's range
    /// clamp to its bounds.
    init(safe value: Double) {
        guard !value.isNaN else { self = 0; return }
        if value >= Double(Int.max) { self = .max; return }
        if value <= Double(Int.min) { self = .min; return }
        self = Int(value)
    }
}

extension Double {
    /// A finite value, or nil. Use at every boundary where a number enters the
    /// app from outside it.
    var finiteValue: Double? { isFinite ? self : nil }
}
