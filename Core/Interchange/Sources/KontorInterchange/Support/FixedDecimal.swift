import Foundation
import KontorModel

/// Locale-independent fixed-point decimal parsing and formatting on integers.
///
/// Everything in Kontor's model is an integer scaled by a power of ten (money ×10², shares and
/// prices ×10⁸). Going through `Double` or `Decimal` would be slower and, for `Double`, lossy.
enum FixedDecimal {
    static let pow10: [Int64] = [
        1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000, 10_000_000_000,
        100_000_000_000, 1_000_000_000_000, 10_000_000_000_000, 100_000_000_000_000, 1_000_000_000_000_000,
        10_000_000_000_000_000, 100_000_000_000_000_000, 1_000_000_000_000_000_000,
    ]

    /// Parses a plain decimal number (`-12.5`, `+3`, `.5`, `1e-3` is *not* supported) with `.` as the
    /// decimal separator into an integer scaled by 10^`digits`, rounding half away from zero.
    /// Returns nil for malformed input or overflow.
    static func parse(_ text: some StringProtocol, digits: Int) -> Int64? {
        parse(utf8: Array(text.utf8)[...], digits: digits)
    }

    static func parse(utf8 bytes: ArraySlice<UInt8>, digits: Int) -> Int64? {
        var i = bytes.startIndex
        let end = bytes.endIndex
        guard i < end else { return nil }
        var negative = false
        if bytes[i] == 45 { negative = true; i += 1 } else if bytes[i] == 43 { i += 1 }
        var value: Int64 = 0
        var seenDigit = false
        var fraction = -1 // number of fraction digits consumed, -1 before the separator
        var roundUp = false
        var decided = false // rounding digit already inspected
        while i < end {
            let c = bytes[i]
            if c == 46 {
                guard fraction < 0 else { return nil }
                fraction = 0
            } else if c >= 48, c <= 57 {
                seenDigit = true
                let d = Int64(c - 48)
                if fraction >= digits {
                    if !decided { roundUp = d >= 5; decided = true }
                } else {
                    let (m, o1) = value.multipliedReportingOverflow(by: 10)
                    let (a, o2) = m.addingReportingOverflow(d)
                    guard !o1, !o2 else { return nil }
                    value = a
                    if fraction >= 0 { fraction += 1 }
                }
            } else {
                return nil
            }
            i += 1
        }
        guard seenDigit else { return nil }
        let missing = digits - max(fraction, 0)
        if missing > 0 {
            guard missing < pow10.count else { return nil }
            let (m, o) = value.multipliedReportingOverflow(by: pow10[missing])
            guard !o else { return nil }
            value = m
        }
        if roundUp {
            let (a, o) = value.addingReportingOverflow(1)
            guard !o else { return nil }
            value = a
        }
        return negative ? -value : value
    }

    /// Formats `raw / 10^digits`.
    /// - Parameters:
    ///   - minFraction: minimum number of fraction digits to keep (trailing zeros beyond it are trimmed).
    ///   - decimalSeparator: separator character to use.
    static func format(_ raw: Int64, digits: Int, minFraction: Int = 0, decimalSeparator: Character = ".") -> String {
        let negative = raw < 0
        let magnitude = raw.magnitude
        let scale = UInt64(pow10[digits])
        let whole = magnitude / scale
        var frac = magnitude % scale
        var fracDigits = digits
        while fracDigits > minFraction, frac % 10 == 0 {
            frac /= 10
            fracDigits -= 1
        }
        var out = negative ? "-" : ""
        out += String(whole)
        if fracDigits > 0 {
            out.append(decimalSeparator)
            let f = String(frac)
            if f.count < fracDigits { out += String(repeating: "0", count: fracDigits - f.count) }
            out += f
        }
        return out
    }
}

/// Deterministic identifiers for source objects that carry no UUID of their own.
enum StableID {
    /// 64-bit FNV-1a.
    static func fnv1a(_ bytes: some Sequence<UInt8>, seed: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 {
        var h = seed
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    /// A reproducible UUID (variant/version bits set like a name-based UUID) for `name`.
    static func uuid(_ name: String) -> UUID {
        let a = fnv1a(name.utf8)
        let b = fnv1a(name.utf8, seed: a ^ 0x9E37_79B9_7F4A_7C15)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: a >> UInt64(56 - i * 8))
            bytes[8 + i] = UInt8(truncatingIfNeeded: b >> UInt64(56 - i * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// ISO-8601 instants (`2024-02-16T07:17:00.710440Z`) without `DateFormatter`.
enum ISOInstant {
    static func parse(_ text: String) -> Date? {
        let u = Array(text.utf8)
        guard u.count >= 16, let day = Day(iso: text), u[10] == 84 || u[10] == 32 else { return nil }
        func two(_ i: Int) -> Int? {
            guard i + 1 < u.count, u[i] >= 48, u[i] <= 57, u[i + 1] >= 48, u[i + 1] <= 57 else { return nil }
            return Int(u[i] - 48) * 10 + Int(u[i + 1] - 48)
        }
        guard let h = two(11), u[13] == 58, let m = two(14) else { return nil }
        var seconds = Double(h * 3600 + m * 60)
        var i = 16
        if i < u.count, u[i] == 58, let s = two(i + 1) {
            seconds += Double(s)
            i += 3
            if i < u.count, u[i] == 46 {
                i += 1
                var scale = 0.1
                while i < u.count, u[i] >= 48, u[i] <= 57 {
                    seconds += Double(u[i] - 48) * scale
                    scale /= 10
                    i += 1
                }
            }
        }
        var offset = 0.0
        if i < u.count, u[i] == 43 || u[i] == 45, let oh = two(i + 1) {
            let om = two(i + 4) ?? two(i + 3) ?? 0
            offset = Double(oh * 3600 + om * 60) * (u[i] == 45 ? -1 : 1)
        }
        return Date(timeIntervalSince1970: Double(day.rawValue) * 86_400 + seconds - offset)
    }

    /// Formats with microsecond precision (fraction omitted when zero), always in UTC.
    static func format(_ date: Date) -> String {
        let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        let dayLength: Int64 = 86_400_000_000
        var dayNumber = micros / dayLength
        var rest = micros % dayLength
        if rest < 0 { rest += dayLength; dayNumber -= 1 }
        let secs = Int(rest / 1_000_000), frac = Int(rest % 1_000_000)
        func pad(_ v: Int, _ n: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, n - s.count)) + s
        }
        var out = Day(rawValue: Int32(dayNumber)).iso + "T" + pad(secs / 3600, 2) + ":" + pad(secs / 60 % 60, 2) + ":" + pad(secs % 60, 2)
        if frac != 0 { out += "." + pad(frac, 6) }
        return out + "Z"
    }
}

/// Allocation-free number and date rendering into byte buffers (bulk output such as price lists).
enum ByteFormatting {
    static func appendInteger(_ value: Int64, to output: inout [UInt8]) {
        var magnitude = value.magnitude
        if value < 0 { output.append(45) }
        if magnitude == 0 {
            output.append(48)
            return
        }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { buffer in
            var count = 0
            while magnitude > 0 {
                buffer[count] = UInt8(48 + magnitude % 10)
                magnitude /= 10
                count += 1
            }
            while count > 0 {
                count -= 1
                output.append(buffer[count])
            }
        }
    }

    /// Appends `yyyy-MM-dd`.
    static func appendISODate(_ day: Day, to output: inout [UInt8]) {
        let c = day.ymd
        guard c.year >= 0, c.year <= 9999 else {
            output.append(contentsOf: day.iso.utf8)
            return
        }
        output.append(UInt8(48 + c.year / 1000))
        output.append(UInt8(48 + c.year / 100 % 10))
        output.append(UInt8(48 + c.year / 10 % 10))
        output.append(UInt8(48 + c.year % 10))
        output.append(45)
        output.append(UInt8(48 + c.month / 10))
        output.append(UInt8(48 + c.month % 10))
        output.append(45)
        output.append(UInt8(48 + c.day / 10))
        output.append(UInt8(48 + c.day % 10))
    }
}
