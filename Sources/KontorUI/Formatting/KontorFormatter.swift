import Foundation
import KontorModel

/// A locale-specific number/date formatter tuned for table cells: everything is formatted with
/// integer arithmetic into a byte buffer, with no `NumberFormatter`/`DateFormatter` on the hot path.
/// Locale conventions (separators, currency placement, date patterns, month names) are read from
/// Foundation once when the formatter is created.
///
/// Most code uses the static facade ``Fmt``; create your own instance only for a specific locale
/// (tests, previews, exports).
public struct KontorFormatter: Sendable {
    public let locale: Locale
    let spec: Spec

    public init(locale: Locale = .autoupdatingCurrent) {
        self.locale = locale
        self.spec = Spec(locale: locale)
    }

    /// Placeholder shown for missing / non-finite values.
    public static let missing = "–"

    // MARK: Money

    /// Formats an amount: `1,234.56` / `1.234,56`, optionally with the currency symbol in the
    /// locale's position (`$1,234.56`, `1.234,56 €`). `signed` adds an explicit `+` for positive values.
    public func money(_ money: Money, symbol: Bool = true, signed: Bool = false) -> String {
        self.money(minor: money.minor, currency: symbol ? money.currency : nil, signed: signed)
    }

    /// Formats minor units (1/100). Pass `currency: nil` for a bare number.
    public func money(minor: Int64, currency: CurrencyCode? = nil, signed: Bool = false) -> String {
        var out = [UInt8]()
        out.reserveCapacity(24)
        appendSign(minor < 0, positive: signed && minor > 0, &out)
        let body = { (out: inout [UInt8]) in
            self.appendFixed(minor.magnitude, scaleDigits: 2, minFraction: 2, maxFraction: 2, grouping: true, &out)
        }
        wrapCurrency(currency, &out, body)
        return String(decoding: out, as: UTF8.self)
    }

    /// Whole currency units without decimals (`$1,235`) — for axis labels and dense summaries.
    public func moneyRounded(_ money: Money, symbol: Bool = true, signed: Bool = false) -> String {
        var out = [UInt8]()
        let rounded = (money.minor.magnitude + 50) / 100
        appendSign(money.minor < 0 && rounded != 0, positive: signed && money.minor > 0 && rounded != 0, &out)
        wrapCurrency(symbol ? money.currency : nil, &out) { out in
            self.appendFixed(rounded, scaleDigits: 0, minFraction: 0, maxFraction: 0, grouping: true, &out)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Compact amount for tiles and chart axes: `$1.2M`, `1,2 Mio. €`, `$950`.
    public func compactMoney(_ money: Money, symbol: Bool = true) -> String {
        var out = [UInt8]()
        appendSign(money.minor < 0, positive: false, &out)
        wrapCurrency(symbol ? money.currency : nil, &out) { out in
            self.appendCompact(money.minor.magnitude, &out)
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Numbers

    /// Formats a fraction as a percentage: `0.1234` → `12.34%` (`12,34 %` in German).
    public func percent(_ fraction: Double, decimals: Int = 2, signed: Bool = false) -> String {
        let d = max(0, min(decimals, 8))
        let scaled = fraction * 100 * Self.pow10Double[d]
        guard scaled.isFinite, abs(scaled) < 9e17 else { return Self.missing }
        let value = Int64(scaled.rounded(.toNearestOrAwayFromZero))
        var out = [UInt8]()
        out.reserveCapacity(16)
        appendSign(value < 0, positive: signed && value > 0, &out)
        out.append(contentsOf: spec.percentPrefix)
        appendFixed(value.magnitude, scaleDigits: d, minFraction: d, maxFraction: d, grouping: true, &out)
        out.append(contentsOf: spec.percentSuffix)
        return String(decoding: out, as: UTF8.self)
    }

    /// Formats basis points (10_000 = 100 %) as a percentage.
    public func percent(basisPoints: Int, decimals: Int = 2) -> String {
        percent(Double(basisPoints) / 10_000, decimals: decimals)
    }

    /// Formats a plain decimal number with a fixed number of fraction digits.
    public func number(_ value: Double, decimals: Int = 2, signed: Bool = false, grouping: Bool = true) -> String {
        let d = max(0, min(decimals, 8))
        let scaled = value * Self.pow10Double[d]
        guard scaled.isFinite, abs(scaled) < 9e17 else { return Self.missing }
        let v = Int64(scaled.rounded(.toNearestOrAwayFromZero))
        var out = [UInt8]()
        appendSign(v < 0, positive: signed && v > 0, &out)
        appendFixed(v.magnitude, scaleDigits: d, minFraction: d, maxFraction: d, grouping: grouping, &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// Formats an integer with grouping separators.
    public func integer(_ value: Int) -> String {
        var out = [UInt8]()
        appendSign(value < 0, positive: false, &out)
        appendFixed(UInt64(value.magnitude), scaleDigits: 0, minFraction: 0, maxFraction: 0, grouping: true, &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// Share counts: up to 8 decimals, trailing zeros trimmed (`12`, `0.5`, `1,234.56789`).
    ///
    /// `maxDecimals` rounds for dense table cells (`3.85239567` → `3.8524` with 4); the exact value
    /// belongs in a tooltip, an inspector or an editor.
    public func shares(_ shares: Shares, signed: Bool = false, maxDecimals: Int = 8) -> String {
        var out = [UInt8]()
        let magnitude = Self.rounded(shares.raw.magnitude, toDecimals: maxDecimals)
        appendSign(shares.raw < 0 && magnitude != 0, positive: signed && shares.raw > 0, &out)
        appendFixed(magnitude, scaleDigits: 8, minFraction: 0, maxFraction: max(0, min(maxDecimals, 8)), grouping: true, &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// Rounds a value with 8 implied decimals half-up to `decimals` decimals (still scaled by 10⁸).
    private static func rounded(_ raw: UInt64, toDecimals decimals: Int) -> UInt64 {
        let d = max(0, min(decimals, 8))
        guard d < 8 else { return raw }
        var step: UInt64 = 1
        for _ in 0..<(8 - d) { step *= 10 }
        let (sum, overflow) = raw.addingReportingOverflow(step / 2)
        return overflow ? raw : sum / step * step
    }

    /// Quotes: at least 2 decimals; up to 4 for prices ≥ 1 and up to 8 below (penny stocks, crypto).
    ///
    /// `maxDecimals` caps the fraction digits (never below 2) — for engine-derived values such as a
    /// dividend per share or an average purchase price in a table cell.
    public func price(_ price: Price, currency: CurrencyCode? = nil, maxDecimals: Int? = nil) -> String {
        var out = [UInt8]()
        var magnitude = price.raw.magnitude
        var maxFraction = magnitude >= UInt64(Scale.price) ? 4 : 8
        if let maxDecimals { maxFraction = min(maxFraction, max(2, maxDecimals)) }
        magnitude = Self.rounded(magnitude, toDecimals: maxFraction)
        appendSign(price.raw < 0 && magnitude != 0, positive: false, &out)
        wrapCurrency(currency, &out) { out in
            self.appendFixed(magnitude, scaleDigits: 8, minFraction: 2, maxFraction: maxFraction, grouping: true, &out)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// A time of day given as minutes after midnight, 24-hour: `495` → `08:15`.
    public func time(minuteOfDay: Int) -> String {
        let m = ((minuteOfDay % 1440) + 1440) % 1440
        let digits = [m / 60 / 10, m / 60 % 10, m % 60 / 10, m % 60 % 10].map { UInt8(48 + $0) }
        return String(decoding: [digits[0], digits[1], UInt8(ascii: ":"), digits[2], digits[3]], as: UTF8.self)
    }

    /// A file size: `850 bytes`, `12.4 KB`, `74.1 MB` (decimal units, as Finder shows them).
    public func bytes(_ count: Int) -> String {
        let n = Double(max(0, count))
        if n < 1000 { return "\(integer(Int(n))) \(Int(n) == 1 ? "byte" : "bytes")" }
        if n < 1e6 { return "\(number(n / 1e3, decimals: n < 1e4 ? 1 : 0)) KB" }
        if n < 1e9 { return "\(number(n / 1e6, decimals: 1)) MB" }
        return "\(number(n / 1e9, decimals: 2)) GB"
    }

    /// An exchange rate with 4 decimals.
    public func rate(_ rate: Double) -> String { number(rate, decimals: 4) }

    /// The display symbol for a currency in this locale (`€`, `$`, `CHF`).
    public func currencySymbol(_ code: CurrencyCode) -> String { spec.symbol(for: code) }

    // MARK: Days

    public enum DayStyle: Sendable, CaseIterable {
        /// Numeric, zero padded for column alignment: `03/31/2024`, `31.03.2024`.
        case short
        /// `Mar 31, 2024`, `31. März 2024`.
        case medium
        /// `March 31, 2024`.
        case long
        /// `March 2024`.
        case monthYear
        /// `Mar 2024`.
        case shortMonthYear
        /// `Mar 31` — axis ticks within one year.
        case dayMonth
        /// `2024-03-31`.
        case iso
    }

    public func day(_ day: Day, style: DayStyle = .short) -> String {
        if style == .iso { return day.iso }
        let c = day.ymd
        var out = [UInt8]()
        out.reserveCapacity(16)
        for token in spec.pattern(style) {
            switch token {
            case .day(let pad): Self.appendInt(c.day, pad: pad ? 2 : 1, &out)
            case .month(let pad): Self.appendInt(c.month, pad: pad ? 2 : 1, &out)
            case .monthShort: out.append(contentsOf: spec.monthsShort[c.month - 1])
            case .monthLong: out.append(contentsOf: spec.monthsLong[c.month - 1])
            case .monthShortStandalone: out.append(contentsOf: spec.monthsShortStandalone[c.month - 1])
            case .monthLongStandalone: out.append(contentsOf: spec.monthsLongStandalone[c.month - 1])
            case .year(let digits):
                if digits == 2 { Self.appendInt(((c.year % 100) + 100) % 100, pad: 2, &out) } else { Self.appendInt(c.year, pad: 1, &out) }
            case .literal(let bytes): out.append(contentsOf: bytes)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `Today`, `Yesterday`, `3 days ago` for days within a week of `today`; medium style otherwise.
    public func relativeDay(_ day: Day, today: Day = .today) -> String {
        let diff = today.distance(to: day)
        switch diff {
        case 0: return spec.todayName
        case -1: return spec.yesterdayName
        case 1: return spec.tomorrowName
        case -6...6: return spec.relative(days: diff)
        default: return self.day(day, style: .medium)
        }
    }

    // MARK: Parsing

    /// Parses user input into a fixed-point integer with `scaleDigits` decimals. Tolerant of either
    /// decimal separator, grouping separators, currency symbols, `%`, surrounding whitespace,
    /// a leading `-`/`−`/`+` and accounting parentheses. Returns nil for input without digits or on overflow.
    public func parseFixed(_ text: String, scaleDigits: Int) -> Int64? {
        var negative = false
        var sawDigit = false
        var chars = [UInt8]()
        chars.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "0"..."9":
                sawDigit = true
                chars.append(UInt8(scalar.value))
            case ".", ",":
                chars.append(UInt8(scalar.value))
            case "-", "\u{2212}", "\u{2012}", "\u{2013}":
                if !sawDigit { negative = true }
            case "(":
                if !sawDigit { negative = true }
            default:
                continue
            }
        }
        guard sawDigit else { return nil }

        // Decide which of '.' / ',' is the decimal separator.
        var dots = 0, commas = 0, lastDot = -1, lastComma = -1
        for (i, c) in chars.enumerated() {
            if c == 0x2E { dots += 1; lastDot = i } else if c == 0x2C { commas += 1; lastComma = i }
        }
        var decimalIndex = -1
        if dots > 0, commas > 0 {
            decimalIndex = max(lastDot, lastComma)
        } else if dots + commas == 1 {
            let index = max(lastDot, lastComma)
            let char = chars[index]
            let digitsAfter = chars.count - index - 1
            let looksLikeGrouping = digitsAfter == 3 && index >= 1 && index <= 3
            if char == spec.decimalByte || !(looksLikeGrouping && char == spec.groupingByte) {
                decimalIndex = index
            }
        }

        var value: UInt64 = 0
        var fractionDigits = 0
        var roundUp = false
        var inFraction = false
        for (i, c) in chars.enumerated() {
            if c == 0x2E || c == 0x2C {
                if i == decimalIndex { inFraction = true }
                continue
            }
            let digit = UInt64(c - 0x30)
            if inFraction {
                if fractionDigits == scaleDigits {
                    roundUp = digit >= 5
                    break
                }
                fractionDigits += 1
            }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (a, o2) = m.addingReportingOverflow(digit)
            if o1 || o2 { return nil }
            value = a
        }
        while fractionDigits < scaleDigits {
            let (m, o) = value.multipliedReportingOverflow(by: 10)
            if o { return nil }
            value = m
            fractionDigits += 1
        }
        if roundUp { value += 1 }
        guard value <= UInt64(Int64.max) else { return nil }
        return negative ? -Int64(value) : Int64(value)
    }

    /// Parses an amount into minor units (1/100).
    public func parseMinor(_ text: String) -> Int64? { parseFixed(text, scaleDigits: 2) }
    public func parseMoney(_ text: String, currency: CurrencyCode) -> Money? {
        parseMinor(text).map { Money(minor: $0, currency: currency) }
    }
    public func parseShares(_ text: String) -> Shares? { parseFixed(text, scaleDigits: 8).map(Shares.init(raw:)) }
    public func parsePrice(_ text: String) -> Price? { parseFixed(text, scaleDigits: 8).map(Price.init(raw:)) }
    /// Parses `"12.5"`, `"12,5 %"` → `0.125`.
    public func parsePercent(_ text: String) -> Double? {
        parseFixed(text, scaleDigits: 6).map { Double($0) / 100_000_000 }
    }
    public func parseDouble(_ text: String) -> Double? {
        parseFixed(text, scaleDigits: 8).map { Double($0) / 100_000_000 }
    }

    /// Parses a typed date: ISO (`2024-03-31`, `20240331`), the locale's numeric order (`31.3.24`,
    /// `3/31/2024`), or day + month only (the year of `today` is assumed).
    public func parseDay(_ text: String, today: Day = .today) -> Day? {
        var groups = [(value: Int, digits: Int)]()
        var current = 0, digits = 0
        for c in text.utf8 {
            if c >= 0x30, c <= 0x39 {
                guard digits < 9 else { return nil }
                current = current * 10 + Int(c - 0x30)
                digits += 1
            } else if digits > 0 {
                groups.append((current, digits))
                current = 0
                digits = 0
            }
        }
        if digits > 0 { groups.append((current, digits)) }

        func make(_ y: Int, _ m: Int, _ d: Int) -> Day? {
            guard (1...12).contains(m), d >= 1, d <= Day.daysInMonth(year: y, month: m), (1...9999).contains(y) else { return nil }
            return Day(year: y, month: m, day: d)
        }
        func fullYear(_ y: Int, _ digits: Int) -> Int {
            guard digits <= 2 else { return y }
            let pivot = today.year % 100 + 20
            return y <= pivot ? 2000 + y : 1900 + y
        }
        switch groups.count {
        case 1 where groups[0].digits == 8:
            let v = groups[0].value
            return make(v / 10_000, v / 100 % 100, v % 100)
        case 2:
            let (a, b) = (groups[0].value, groups[1].value)
            return spec.dayBeforeMonth ? make(today.year, b, a) : make(today.year, a, b)
        case 3:
            if groups[0].digits == 4 { return make(groups[0].value, groups[1].value, groups[2].value) }
            let y = fullYear(groups[2].value, groups[2].digits)
            let (a, b) = (groups[0].value, groups[1].value)
            return spec.dayBeforeMonth ? make(y, b, a) : make(y, a, b)
        default:
            return nil
        }
    }

    // MARK: - Digit engine

    static let pow10Double: [Double] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000]
    static let pow10: [UInt64] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000]

    private func appendSign(_ negative: Bool, positive: Bool, _ out: inout [UInt8]) {
        if negative { out.append(contentsOf: spec.minus) } else if positive { out.append(0x2B) }
    }

    private func wrapCurrency(_ currency: CurrencyCode?, _ out: inout [UInt8], _ body: (inout [UInt8]) -> Void) {
        guard let currency else { return body(&out) }
        let symbol = spec.symbolBytes(for: currency)
        if spec.currencyBefore {
            out.append(contentsOf: symbol)
            out.append(contentsOf: spec.currencySpacing(symbol: symbol))
            body(&out)
        } else {
            body(&out)
            out.append(contentsOf: spec.currencySpacingAfter)
            out.append(contentsOf: symbol)
        }
    }

    /// Appends `magnitude / 10^scaleDigits`, rounded half away from zero to `maxFraction` digits and
    /// with trailing zeros trimmed down to `minFraction`.
    func appendFixed(
        _ magnitude: UInt64, scaleDigits: Int, minFraction: Int, maxFraction: Int, grouping: Bool, _ out: inout [UInt8]
    ) {
        var value = magnitude
        var scale = scaleDigits
        if maxFraction < scale {
            let divisor = Self.pow10[scale - maxFraction]
            let (q, r) = value.quotientAndRemainder(dividingBy: divisor)
            value = r >= divisor - r ? q + 1 : q
            scale = maxFraction
        }
        let unit = Self.pow10[scale]
        let whole = value / unit
        var fraction = value % unit
        var fractionDigits = scale
        while fractionDigits > minFraction, fraction % 10 == 0 {
            fraction /= 10
            fractionDigits -= 1
        }

        // Integer part with grouping.
        var digits = [UInt8](repeating: 0, count: 20)
        var n = 0
        var w = whole
        repeat {
            digits[n] = UInt8(w % 10) + 0x30
            n += 1
            w /= 10
        } while w > 0
        let useGrouping = grouping && spec.groupSize > 0 && n > spec.groupSize && (n > 4 || !spec.skipsGroupingForFourDigits)
        var i = n - 1
        while i >= 0 {
            out.append(digits[i])
            if useGrouping, i > 0 {
                if i == spec.groupSize || (i > spec.groupSize && (i - spec.groupSize) % spec.secondaryGroupSize == 0) {
                    out.append(contentsOf: spec.groupSeparator)
                }
            }
            i -= 1
        }
        if fractionDigits > 0 {
            out.append(contentsOf: spec.decimalSeparator)
            var divisor = Self.pow10[fractionDigits - 1]
            for _ in 0..<fractionDigits {
                out.append(UInt8(fraction / divisor % 10) + 0x30)
                divisor = max(divisor / 10, 1)
            }
        }
    }

    private func appendCompact(_ minorMagnitude: UInt64, _ out: inout [UInt8]) {
        let units = (minorMagnitude + 50) / 100
        guard units >= 1_000 else {
            appendFixed(units, scaleDigits: 0, minFraction: 0, maxFraction: 0, grouping: false, &out)
            return
        }
        // Pick the largest tier; show one decimal below 100 of that tier ("1.2M", "123M").
        var tier = 0
        var divisor: UInt64 = 1_000
        while tier < 3, units >= divisor * 1_000 {
            divisor *= 1_000
            tier += 1
        }
        var tenths = (units * 10 + divisor / 2) / divisor
        if tenths >= 10_000, tier < 3 {
            // Rounding carried into the next tier (999.96K → 1.0M).
            tier += 1
            divisor *= 1_000
            tenths = (units * 10 + divisor / 2) / divisor
        }
        if tenths >= 1_000 {
            appendFixed((units + divisor / 2) / divisor, scaleDigits: 0, minFraction: 0, maxFraction: 0, grouping: true, &out)
        } else {
            appendFixed(tenths, scaleDigits: 1, minFraction: 1, maxFraction: 1, grouping: false, &out)
        }
        out.append(contentsOf: spec.compactSuffixes[tier])
    }

    private static func appendInt(_ value: Int, pad: Int, _ out: inout [UInt8]) {
        var digits = [UInt8]()
        var v = abs(value)
        repeat {
            digits.append(UInt8(v % 10) + 0x30)
            v /= 10
        } while v > 0
        if value < 0 { out.append(0x2D) }
        for _ in stride(from: digits.count, to: pad, by: 1) { out.append(0x30) }
        out.append(contentsOf: digits.reversed())
    }
}

// MARK: - Locale conventions

extension KontorFormatter {
    enum DateToken: Sendable {
        case day(pad: Bool), month(pad: Bool), monthShort, monthLong, monthShortStandalone, monthLongStandalone
        case year(digits: Int), literal([UInt8])
    }

    /// Immutable locale conventions plus a small lock-protected currency symbol cache.
    final class Spec: @unchecked Sendable {
        let decimalSeparator: [UInt8]
        let groupSeparator: [UInt8]
        let decimalByte: UInt8
        let groupingByte: UInt8
        let groupSize: Int
        let secondaryGroupSize: Int
        let skipsGroupingForFourDigits: Bool
        let minus: [UInt8]
        let percentPrefix: [UInt8]
        let percentSuffix: [UInt8]
        let currencyBefore: Bool
        let currencySpacingAfter: [UInt8]
        let compactSuffixes: [[UInt8]]
        let monthsShort: [[UInt8]]
        let monthsLong: [[UInt8]]
        let monthsShortStandalone: [[UInt8]]
        let monthsLongStandalone: [[UInt8]]
        let patterns: [DayStyle: [DateToken]]
        let dayBeforeMonth: Bool
        let todayName: String
        let yesterdayName: String
        let tomorrowName: String

        private let locale: Locale
        private let lock = NSLock()
        private var symbols: [CurrencyCode: [UInt8]] = [:]
        private var relativeCache: [Int: String] = [:]

        init(locale: Locale) {
            self.locale = locale
            let nf = NumberFormatter()
            nf.locale = locale
            nf.numberStyle = .decimal
            let decimal = nf.decimalSeparator ?? "."
            let group = nf.groupingSeparator ?? ","
            decimalSeparator = Array(decimal.utf8)
            groupSeparator = Array(group.utf8)
            decimalByte = decimal == "," ? 0x2C : 0x2E
            groupingByte = group == "." ? 0x2E : (group == "," ? 0x2C : 0)
            groupSize = nf.usesGroupingSeparator ? nf.groupingSize : 0
            secondaryGroupSize = nf.secondaryGroupingSize > 0 ? nf.secondaryGroupingSize : max(nf.groupingSize, 1)
            // Some locales (es, pl, pt-PT) only group from five digits on.
            skipsGroupingForFourDigits = nf.string(from: 1234)?.count == 4
            minus = Array((nf.minusSign ?? "-").utf8)

            let pf = NumberFormatter()
            pf.locale = locale
            pf.numberStyle = .percent
            let percentSample = pf.string(from: 0.01) ?? "1%"
            let (pPrefix, pSuffix) = Self.affixes(of: percentSample)
            percentPrefix = Array(pPrefix.utf8)
            percentSuffix = Array(pSuffix.utf8)

            let cf = NumberFormatter()
            cf.locale = locale
            cf.numberStyle = .currency
            cf.currencyCode = "EUR"
            let (cPrefix, cSuffix) = Self.affixes(of: cf.string(from: 1) ?? "€1")
            currencyBefore = !cPrefix.isEmpty
            let trailingSpace = cSuffix.prefix { $0.isWhitespace }
            currencySpacingAfter = Array((trailingSpace.isEmpty && !currencyBefore ? "\u{00A0}" : String(trailingSpace)).utf8)

            switch locale.language.languageCode?.identifier {
            case "de": compactSuffixes = ["\u{00A0}Tsd.", "\u{00A0}Mio.", "\u{00A0}Mrd.", "\u{00A0}Bio."].map { Array($0.utf8) }
            case "fr": compactSuffixes = ["\u{00A0}k", "\u{00A0}M", "\u{00A0}Md", "\u{00A0}Bn"].map { Array($0.utf8) }
            default: compactSuffixes = ["K", "M", "B", "T"].map { Array($0.utf8) }
            }

            let df = DateFormatter()
            df.locale = locale
            df.calendar = Calendar(identifier: .gregorian)
            df.timeZone = TimeZone(identifier: "UTC")
            monthsShort = (df.shortMonthSymbols ?? []).map { Array($0.utf8) }
            monthsLong = (df.monthSymbols ?? []).map { Array($0.utf8) }
            monthsShortStandalone = (df.shortStandaloneMonthSymbols ?? []).map { Array($0.utf8) }
            monthsLongStandalone = (df.standaloneMonthSymbols ?? []).map { Array($0.utf8) }

            func pattern(_ template: String, fallback: String) -> [DateToken] {
                Self.tokens(DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) ?? fallback)
            }
            var p: [DayStyle: [DateToken]] = [:]
            p[.short] = pattern("yyyyMMdd", fallback: "yyyy-MM-dd")
            p[.medium] = pattern("yMMMd", fallback: "d MMM y")
            p[.long] = pattern("yMMMMd", fallback: "d MMMM y")
            p[.monthYear] = pattern("yMMMM", fallback: "MMMM y")
            p[.shortMonthYear] = pattern("yMMM", fallback: "MMM y")
            p[.dayMonth] = pattern("MMMd", fallback: "d MMM")
            patterns = p
            var dayFirst = true
            for token in p[.short] ?? [] {
                if case .day = token { dayFirst = true; break }
                if case .month = token { dayFirst = false; break }
            }
            dayBeforeMonth = dayFirst

            let rf = DateFormatter()
            rf.locale = locale
            rf.dateStyle = .medium
            rf.timeStyle = .none
            rf.doesRelativeDateFormatting = true
            let now = Date()
            todayName = rf.string(from: now)
            yesterdayName = rf.string(from: now.addingTimeInterval(-86_400))
            tomorrowName = rf.string(from: now.addingTimeInterval(86_400))
        }

        func pattern(_ style: DayStyle) -> [DateToken] { patterns[style] ?? [] }

        func symbolBytes(for code: CurrencyCode) -> [UInt8] {
            lock.lock()
            defer { lock.unlock() }
            if let cached = symbols[code] { return cached }
            let nf = NumberFormatter()
            nf.locale = locale
            nf.numberStyle = .currency
            nf.currencyCode = code
            var symbol = nf.currencySymbol ?? code
            if symbol.isEmpty || symbol == "¤" { symbol = code }
            let bytes = Array(symbol.utf8)
            symbols[code] = bytes
            return bytes
        }

        func symbol(for code: CurrencyCode) -> String { String(decoding: symbolBytes(for: code), as: UTF8.self) }

        /// Between a leading symbol and the number: nothing for true symbols ("$1"), a no-break
        /// space after alphabetic codes ("CHF 1").
        func currencySpacing(symbol: [UInt8]) -> [UInt8] {
            guard let last = symbol.last else { return [] }
            let isLetter = (last >= 0x41 && last <= 0x5A) || (last >= 0x61 && last <= 0x7A)
            return isLetter ? [0xC2, 0xA0] : []
        }

        func relative(days: Int) -> String {
            lock.lock()
            defer { lock.unlock() }
            if let cached = relativeCache[days] { return cached }
            let rf = RelativeDateTimeFormatter()
            rf.locale = locale
            rf.unitsStyle = .full
            let s = rf.localizedString(from: DateComponents(day: days))
            relativeCache[days] = s
            return s
        }

        /// Splits a formatted sample like "1 %" or "€1.00" into what precedes and follows the digits.
        static func affixes(of sample: String) -> (prefix: String, suffix: String) {
            guard let first = sample.firstIndex(where: \.isNumber), let last = sample.lastIndex(where: \.isNumber) else {
                return ("", "")
            }
            return (String(sample[..<first]), String(sample[sample.index(after: last)...]))
        }

        /// Compiles an ICU date pattern (day/month/year fields and literals only).
        static func tokens(_ pattern: String) -> [DateToken] {
            var result = [DateToken]()
            var literal = ""
            func flush() {
                if !literal.isEmpty {
                    result.append(.literal(Array(literal.utf8)))
                    literal = ""
                }
            }
            let chars = Array(pattern)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c == "'" {
                    // Quoted literal; '' is an escaped quote.
                    if i + 1 < chars.count, chars[i + 1] == "'" {
                        literal.append("'")
                        i += 2
                        continue
                    }
                    i += 1
                    while i < chars.count, chars[i] != "'" {
                        literal.append(chars[i])
                        i += 1
                    }
                    i += 1
                    continue
                }
                guard c.isASCII, c.isLetter else {
                    literal.append(c)
                    i += 1
                    continue
                }
                var run = 1
                while i + run < chars.count, chars[i + run] == c { run += 1 }
                i += run
                switch c {
                case "d": flush(); result.append(.day(pad: run >= 2))
                case "M":
                    flush()
                    result.append(run >= 4 ? .monthLong : run == 3 ? .monthShort : .month(pad: run == 2))
                case "L":
                    flush()
                    result.append(run >= 4 ? .monthLongStandalone : run == 3 ? .monthShortStandalone : .month(pad: run == 2))
                case "y", "u": flush(); result.append(.year(digits: run == 2 ? 2 : 4))
                default: break // eras, weekdays etc. are not part of a Day
                }
            }
            flush()
            return result
        }
    }
}
