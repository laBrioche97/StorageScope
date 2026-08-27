/// Arithmetic used for file-system counters that must never terminate a long scan.
///
/// File sizes and item counts are non-negative by definition. Providers can still
/// return malformed values and aggregate logical sizes can exceed the representable
/// range (notably with sparse files), so both operands are normalized before adding.
package enum SaturatingArithmetic {
    @inline(__always)
    package static func addNonnegative<Value>(
        _ lhs: Value,
        _ rhs: Value
    ) -> Value where Value: FixedWidthInteger & SignedInteger {
        let normalizedLHS = Swift.max(.zero, lhs)
        let normalizedRHS = Swift.max(.zero, rhs)
        let (sum, overflow) = normalizedLHS.addingReportingOverflow(normalizedRHS)
        return overflow ? .max : sum
    }
}
