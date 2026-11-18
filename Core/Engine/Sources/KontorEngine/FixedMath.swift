import Foundation
import KontorModel

/// Integer helpers shared by all calculations. Every valuation in the engine goes through these
/// functions so that independently computed numbers (snapshots, daily series, breakdowns) agree
/// to the last minor unit.
public enum FixedMath {
    /// Weights are expressed in basis points; `fullWeight` is 100 %.
    public static let fullWeight: Int32 = 10_000

    /// Market value in minor units of `sharesRaw` (1e-8 shares) at `priceRaw` (1e-8 currency units),
    /// rounded half away from zero. Bit-identical to `Price.value(of:)` but several times faster for
    /// the common case (non-negative operands below 1e14) because it avoids 128-bit division.
    @inlinable
    public static func marketValue(priceRaw: Int64, sharesRaw: Int64) -> Int64 {
        let limit: Int64 = 100_000_000_000_000 // 1e14 = price scale × share scale / amount scale
        if priceRaw >= 0, sharesRaw >= 0, priceRaw < limit, sharesRaw < limit {
            // p·s = (p1·k + p0)(s1·k + s0) with k = 1e7, k² = 1e14 = divisor.
            let k: Int64 = 10_000_000
            let p1 = priceRaw / k, p0 = priceRaw % k
            let s1 = sharesRaw / k, s0 = sharesRaw % k
            let cross = p1 * s0 + p0 * s1 // < 2e14
            let c1 = cross / k, c0 = cross % k
            let rest = c0 * k + p0 * s0 // < 2e14
            let q = rest / limit, r = rest % limit
            return p1 * s1 + c1 + q + (r * 2 >= limit ? 1 : 0)
        }
        return mulDiv(priceRaw, sharesRaw, limit)
    }

    /// Market value of `shares` at `price` in minor units.
    @inlinable
    public static func marketValue(price: Price, shares: Shares) -> Int64 {
        marketValue(priceRaw: price.raw, sharesRaw: shares.raw)
    }

    /// `minor × rate`, rounded half away from zero. A non-finite rate or result yields 0
    /// (callers flag the missing rate separately).
    @inlinable
    public static func convert(_ minor: Int64, rate: Double) -> Int64 {
        let x = (Double(minor) * rate).rounded()
        guard x.isFinite, abs(x) < 9.2e18 else { return 0 }
        return Int64(x)
    }

    /// `value` rounded half away from zero and clamped to the `Int64` range (NaN yields 0). Use it
    /// wherever a floating-point intermediate becomes a fixed-point number, so that extreme inputs
    /// (a quote of 0.00000001, a huge order) saturate instead of trapping.
    @inlinable
    public static func saturatingInt64(_ value: Double) -> Int64 {
        guard !value.isNaN else { return 0 }
        let x = value.rounded()
        if x >= 9.2e18 { return Int64.max }
        if x <= -9.2e18 { return Int64.min }
        return Int64(x)
    }

    /// `minor × weight / 10 000`, rounded half away from zero.
    @inlinable
    public static func weighted(_ minor: Int64, _ weight: Int32) -> Int64 {
        if weight == fullWeight { return minor }
        if weight == 0 || minor == 0 { return 0 }
        return mulDiv(minor, Int64(weight), Int64(fullWeight))
    }
}
