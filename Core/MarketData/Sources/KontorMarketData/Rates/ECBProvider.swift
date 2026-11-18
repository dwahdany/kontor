import Foundation
import KontorModel

/// One currency whose exchange rates should be brought up to date.
public struct RateRequest: Hashable, Sendable {
    public var currency: CurrencyCode
    /// First day wanted: the day after the last stored rate, or the start of the wanted history.
    public var from: Day
    /// Whether the file already holds rates for this currency.
    public var hasHistory: Bool

    public init(currency: CurrencyCode, from: Day, hasHistory: Bool) {
        self.currency = currency
        self.from = from
        self.hasHistory = hasHistory
    }
}

/// Newly downloaded exchange rates.
public struct RateBatch: Hashable, Sendable {
    /// One series per currency with new data, `base` = the provider's base currency. Contains
    /// only days on or after the requested `from`.
    public var series: [ExchangeRateSeries]
    /// Requested currencies the provider has no rates for.
    public var unsupported: [CurrencyCode]

    public init(series: [ExchangeRateSeries] = [], unsupported: [CurrencyCode] = []) {
        self.series = series
        self.unsupported = unsupported
    }
}

/// A source of daily exchange rates against one base currency.
public protocol ExchangeRateProvider: Sendable {
    /// The currency all delivered series are based on.
    var baseCurrency: CurrencyCode { get }
    /// Downloads what is missing for the given currencies (never includes `baseCurrency`).
    func rates(for requests: [RateRequest]) async throws -> RateBatch
}

/// The three euro reference rate files published by the European Central Bank.
public enum ECBFeed: String, Hashable, Sendable, CaseIterable {
    /// The latest publication day only (~2 kB).
    case daily = "eurofxref-daily.xml"
    /// The past ~90 calendar days (~70 kB).
    case last90Days = "eurofxref-hist-90d.xml"
    /// Everything since 1999-01-04 (~7 MB).
    case full = "eurofxref-hist.xml"

    /// Calendar days before the latest publication that the 90-day file is trusted to cover.
    static let safe90DaySpan = 80

    /// The smallest file containing every publication from `from` on, given the day of the
    /// latest publication. nil if nothing new has been published since `from`.
    public static func smallest(covering from: Day, latestPublication: Day) -> ECBFeed? {
        if from > latestPublication { return nil }
        if from == latestPublication { return .daily }
        // Nothing is published on weekends: a gap of Saturday/Sunday only needs the latest day.
        if from.distance(to: latestPublication) <= 2, (from..<latestPublication).allSatisfy(\.isWeekend) { return .daily }
        return from >= latestPublication.advanced(by: -safe90DaySpan) ? .last90Days : .full
    }
}

/// Euro foreign exchange reference rates of the ECB (published around 16:00 CET on TARGET
/// business days): 1 EUR = `rate` units of the quote currency.
///
/// An update first loads the tiny daily file to learn the latest publication day and the
/// currencies currently published, then — only if more than that one day is missing — the
/// smallest history file that covers the gap.
public struct ECBProvider: ExchangeRateProvider {
    /// Currencies with historical reference rates that are no longer published (they joined the
    /// euro or were suspended). Rates for these exist only in the full history file.
    public static let discontinued: Set<CurrencyCode> = [
        "BGN", "CYP", "EEK", "HRK", "LTL", "LVL", "MTL", "ROL", "RUB", "SIT", "SKK", "TRL",
    ]

    /// The first day of ECB reference rates.
    public static let firstDay = Day(year: 1999, month: 1, day: 4)

    private let http: any HTTPClient
    private let baseURL: String

    public init(http: any HTTPClient, baseURL: String = "https://www.ecb.europa.eu/stats/eurofxref/") {
        self.http = http
        self.baseURL = baseURL
    }

    public var baseCurrency: CurrencyCode { "EUR" }

    public func rates(for requests: [RateRequest]) async throws -> RateBatch {
        let requests = requests.filter { $0.currency != baseCurrency }
        guard !requests.isEmpty else { return RateBatch() }

        let daily = try Self.parse(try await fetch(.daily))
        guard let latest = daily.values.compactMap(\.days.last).max() else {
            throw MarketDataError.malformedResponse("The ECB daily file contains no rates.")
        }

        var wanted = [CurrencyCode: Day]()
        var unsupported = [CurrencyCode]()
        var needsFullHistory = false
        var earliest: Day?
        for request in requests {
            if daily[request.currency] != nil {
                guard request.from.rawValue <= latest else { continue } // up to date
                wanted[request.currency] = request.from
                earliest = min(earliest ?? request.from, request.from)
            } else if Self.discontinued.contains(request.currency) {
                // Historical-only currency: load it once, then leave it alone.
                guard !request.hasHistory else { continue }
                wanted[request.currency] = request.from
                needsFullHistory = true
            } else {
                unsupported.append(request.currency)
            }
        }
        unsupported.sort()
        guard !wanted.isEmpty else { return RateBatch(unsupported: unsupported) }

        var feed = ECBFeed.daily
        if needsFullHistory {
            feed = .full
        } else if let earliest {
            feed = ECBFeed.smallest(covering: earliest, latestPublication: Day(rawValue: latest)) ?? .daily
        }
        let table = feed == .daily ? daily : try Self.parse(try await fetch(feed), currencies: Set(wanted.keys))

        var series = [ExchangeRateSeries]()
        for (currency, from) in wanted.sorted(by: { $0.key < $1.key }) {
            guard let column = table[currency] else { continue }
            // Columns are ascending: cut everything before `from`.
            var lo = 0, hi = column.days.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if column.days[mid] < from.rawValue { lo = mid + 1 } else { hi = mid }
            }
            guard lo < column.days.count else { continue }
            series.append(ExchangeRateSeries(base: baseCurrency, quote: currency, days: Array(column.days[lo...]), rates: Array(column.rates[lo...])))
        }
        return RateBatch(series: series, unsupported: unsupported)
    }

    private func fetch(_ feed: ECBFeed) async throws -> Data {
        guard let url = URL(string: baseURL + feed.rawValue) else { throw MarketDataError.invalidURL(baseURL + feed.rawValue) }
        return try await http.get(url, headers: ["User-Agent": UserAgent.minimal, "Accept": "application/xml, text/xml"], timeout: 60)
    }

    // MARK: Parsing

    /// The rates of one currency, ascending by day.
    public struct Column: Hashable, Sendable {
        public var days: [Int32] = []
        public var rates: [Double] = []
    }

    /// Parses any of the three ECB files into per-currency columns (ascending days).
    ///
    /// The format is a fixed nesting of `<Cube time="…">` elements containing
    /// `<Cube currency="…" rate="…"/>` elements; it is scanned directly on the UTF-8 bytes, which
    /// handles the 7 MB history file in a few milliseconds and needs no XML library.
    ///
    /// - Parameter currencies: restricts the result to these currencies (nil = all).
    public static func parse(_ data: Data, currencies: Set<CurrencyCode>? = nil) throws -> [CurrencyCode: Column] {
        var columns = [[Int32]]()
        var rates = [[Double]]()
        var slots = [UInt32: Int]()          // packed 3-letter code → column index (−1 = filtered out)
        var codes = [CurrencyCode]()
        var sawCube = false

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            var i = 0
            var day: Int32?
            while i < n {
                // Find the next "<Cube".
                guard b[i] == UInt8(ascii: "<"), i + 5 < n, b[i + 1] == UInt8(ascii: "C"), b[i + 2] == UInt8(ascii: "u"),
                      b[i + 3] == UInt8(ascii: "b"), b[i + 4] == UInt8(ascii: "e") else { i += 1; continue }
                i += 5
                sawCube = true
                var code: UInt32 = 0
                var codeLength = 0
                var rate: Double?
                // Attributes up to the closing '>'.
                while i < n, b[i] != UInt8(ascii: ">") {
                    guard b[i] == UInt8(ascii: "=") else { i += 1; continue }
                    // Attribute name: the letters right before '='.
                    var nameStart = i
                    while nameStart > 0, b[nameStart - 1] >= 97, b[nameStart - 1] <= 122 { nameStart -= 1 }
                    let nameLength = i - nameStart
                    let first = nameLength > 0 ? b[nameStart] : 0
                    i += 1
                    guard i < n, b[i] == UInt8(ascii: "\"") || b[i] == UInt8(ascii: "'") else { continue }
                    let quote = b[i]
                    i += 1
                    let valueStart = i
                    while i < n, b[i] != quote { i += 1 }
                    let value = UnsafeBufferPointer(rebasing: b[valueStart..<min(i, n)])
                    i += 1
                    switch (first, nameLength) {
                    case (UInt8(ascii: "t"), 4): // time
                        day = Day(iso: String(decoding: value, as: UTF8.self))?.rawValue
                    case (UInt8(ascii: "c"), 8): // currency
                        codeLength = value.count
                        if codeLength == 3 { code = UInt32(value[0]) << 16 | UInt32(value[1]) << 8 | UInt32(value[2]) }
                    case (UInt8(ascii: "r"), 4): // rate
                        rate = parseDecimal(value)
                    default:
                        break
                    }
                }
                guard codeLength == 3, let rate, rate > 0, let day else { continue }
                var slot = slots[code]
                if slot == nil {
                    let name = String(decoding: [UInt8(code >> 16), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)], as: UTF8.self)
                    if currencies?.contains(name) ?? true {
                        slot = columns.count
                        columns.append([])
                        rates.append([])
                        codes.append(name)
                    } else {
                        slot = -1
                    }
                    slots[code] = slot
                }
                if let slot, slot >= 0 {
                    columns[slot].append(day)
                    rates[slot].append(rate)
                }
            }
        }
        guard sawCube else { throw MarketDataError.malformedResponse("Not an ECB reference rate file.") }

        var result = [CurrencyCode: Column](minimumCapacity: codes.count)
        for k in codes.indices {
            var days = columns[k], values = rates[k]
            // The files list the newest day first.
            if let first = days.first, let last = days.last, first > last {
                days.reverse()
                values.reverse()
            }
            var ascending = true
            for j in days.indices.dropFirst() where days[j] <= days[j - 1] {
                ascending = false
                break
            }
            if !ascending {
                let sorted = Dictionary(zip(days, values), uniquingKeysWith: { _, last in last }).sorted { $0.key < $1.key }
                days = sorted.map(\.key)
                values = sorted.map(\.value)
            }
            result[codes[k]] = Column(days: days, rates: values)
        }
        return result
    }

    private static let powersOfTen: [Double] = (0...18).map { pow(10, Double($0)) }

    /// Parses a plain decimal ("1.0968", "20020.71"); nil for anything else ("N/A").
    private static func parseDecimal(_ bytes: UnsafeBufferPointer<UInt8>) -> Double? {
        var mantissa: UInt64 = 0
        var digits = 0, fraction = 0
        var seenPoint = false
        for c in bytes {
            if c >= 48, c <= 57 {
                guard digits < 18 else { return Double(String(decoding: bytes, as: UTF8.self)) }
                mantissa = mantissa * 10 + UInt64(c - 48)
                digits += 1
                if seenPoint { fraction += 1 }
            } else if c == UInt8(ascii: "."), !seenPoint {
                seenPoint = true
            } else {
                return nil
            }
        }
        guard digits > 0 else { return nil }
        // Exact for mantissas below 2^53 (always the case for exchange rates).
        return Double(mantissa) / powersOfTen[fraction]
    }
}
