import Foundation

/// SplitMix64 — used to expand a single 64-bit seed into generator state and to derive sub-streams.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The deterministic pseudo-random generator behind all sample data (xoshiro256** seeded via SplitMix64).
///
/// Unlike `SystemRandomNumberGenerator` the sequence only depends on the seed, so everything generated
/// from it — prices, amounts, UUIDs — is reproducible across runs and machines.
public struct SampleRandom: RandomNumberGenerator, Sendable {
    private var s0: UInt64, s1: UInt64, s2: UInt64, s3: UInt64
    private var spare = 0.0
    private var hasSpare = false

    /// A generator whose whole sequence is determined by `seed`.
    public init(seed: UInt64) {
        var mixer = SplitMix64(state: seed)
        s0 = mixer.next()
        s1 = mixer.next()
        s2 = mixer.next()
        s3 = mixer.next()
    }

    /// An independent generator for sub-stream `stream` of `seed` (streams do not overlap in practice).
    public init(seed: UInt64, stream: UInt64) {
        var mixer = SplitMix64(state: seed)
        let base = mixer.next()
        self.init(seed: base ^ (stream &* 0xD6E8_FEB8_6659_FD93 &+ 0x2545_F491_4F6C_DD1D))
    }

    /// A 64-bit seed for sub-stream `stream` of `seed`, for components that take a plain seed.
    public static func subSeed(_ seed: UInt64, stream: UInt64) -> UInt64 {
        var generator = SampleRandom(seed: seed, stream: stream)
        return generator.next()
    }

    /// The next 64 uniformly distributed bits.
    public mutating func next() -> UInt64 {
        let result = ((s1 &* 5) << 7 | (s1 &* 5) >> 57) &* 9
        let t = s1 << 17
        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = s3 << 45 | s3 >> 19
        return result
    }

    /// Uniform in `[0, 1)` with 53 bits of precision.
    public mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }

    /// Uniform in `[low, high)`.
    public mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }

    /// Uniform integer in `0..<bound` (`bound` > 0).
    public mutating func int(below bound: Int) -> Int {
        precondition(bound > 0)
        return Int(next().multipliedFullWidth(by: UInt64(bound)).high)
    }

    /// Uniform integer in a closed range.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + int(below: range.upperBound - range.lowerBound + 1)
    }

    /// Standard normal variate (Box–Muller; the second value of each pair is cached).
    public mutating func gaussian() -> Double {
        if hasSpare {
            hasSpare = false
            return spare
        }
        let radius = (-2 * log(1 - unit())).squareRoot()
        let angle = 2 * Double.pi * unit()
        spare = radius * sin(angle)
        hasSpare = true
        return radius * cos(angle)
    }

    /// A random (version 4, RFC 4122 variant) UUID drawn from this generator.
    public mutating func uuid() -> UUID {
        SampleRandom.makeUUID(high: next(), low: next(), version: 4)
    }

    /// A UUID whose first 48 bits are `sequence` (big-endian) followed by random bits, shaped like a
    /// version 7 UUID. Such ids sort — also as strings — in generation order.
    public mutating func sequencedUUID(_ sequence: UInt64) -> UUID {
        SampleRandom.makeUUID(high: sequence << 16 | next() & 0xFFFF, low: next(), version: 7)
    }

    private static func makeUUID(high: UInt64, low: UInt64, version: UInt8) -> UUID {
        func byte(_ v: UInt64, _ i: Int) -> UInt8 { UInt8(truncatingIfNeeded: v >> UInt64(56 - 8 * i)) }
        return UUID(uuid: (
            byte(high, 0), byte(high, 1), byte(high, 2), byte(high, 3), byte(high, 4), byte(high, 5),
            byte(high, 6) & 0x0F | version << 4, byte(high, 7),
            byte(low, 0) & 0x3F | 0x80, byte(low, 1), byte(low, 2), byte(low, 3), byte(low, 4), byte(low, 5),
            byte(low, 6), byte(low, 7)
        ))
    }
}
