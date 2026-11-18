import Foundation

/// A single dated quote.
public struct PricePoint: Hashable, Sendable {
    public var day: Day
    public var price: Price
    public init(day: Day, price: Price) {
        self.day = day
        self.price = price
    }
}

/// Historical closing prices of one security: strictly ascending days, at most one price per day.
/// Stored column-wise for compact files and cache-friendly lookups.
public struct PriceSeries: Hashable, Sendable, Codable, RandomAccessCollection {
    /// Days since 1970-01-01 (`Day.rawValue`), strictly ascending.
    public private(set) var days: [Int32]
    /// `Price.raw` values, parallel to `days`.
    public private(set) var values: [Int64]

    public init() {
        days = []
        values = []
    }

    /// Builds a series from points in any order; for duplicate days the last one wins.
    public init(_ points: some Sequence<PricePoint>) {
        self.init()
        merge(points)
    }

    /// Bulk-builds a series from parallel columns (`Day.rawValue`s and `Price.raw`s). Columns that are
    /// already strictly ascending are adopted as-is (O(n)); otherwise they are sorted and de-duplicated
    /// (last value per day wins). Extra elements of the longer column are ignored.
    public init(days: [Int32], values: [Int64]) {
        let n = Swift.min(days.count, values.count)
        var ascending = true
        for i in 1..<Swift.max(n, 1) where days[i] <= days[i - 1] { ascending = false; break }
        if ascending {
            self.days = n == days.count ? days : Array(days[..<n])
            self.values = n == values.count ? values : Array(values[..<n])
        } else {
            let sorted = Dictionary(zip(days, values), uniquingKeysWith: { _, last in last }).sorted { $0.key < $1.key }
            self.days = sorted.map(\.key)
            self.values = sorted.map(\.value)
        }
    }

    // MARK: Collection

    public var startIndex: Int { 0 }
    public var endIndex: Int { days.count }
    public subscript(i: Int) -> PricePoint {
        PricePoint(day: Day(rawValue: days[i]), price: Price(raw: values[i]))
    }

    public var firstDay: Day? { days.first.map(Day.init(rawValue:)) }
    public var lastDay: Day? { days.last.map(Day.init(rawValue:)) }
    public var latest: PricePoint? { isEmpty ? nil : self[count - 1] }

    // MARK: Lookup

    /// Index of the last point with `day <= d`, or nil if `d` precedes the series.
    public func index(onOrBefore d: Day) -> Int? {
        var lo = 0, hi = days.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if days[mid] <= d.rawValue { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// The most recent quote on or before `d`.
    public func point(onOrBefore d: Day) -> PricePoint? { index(onOrBefore: d).map { self[$0] } }

    /// The most recent price on or before `d`; if `d` precedes the series and
    /// `fallbackToFirst` is true, the first known price.
    public func price(on d: Day, fallbackToFirst: Bool = true) -> Price? {
        if let i = index(onOrBefore: d) { return Price(raw: values[i]) }
        return fallbackToFirst ? values.first.map(Price.init(raw:)) : nil
    }

    /// Points with `range.lowerBound <= day <= range.upperBound`.
    public func points(in range: ClosedRange<Day>) -> ArraySlice<PricePoint> {
        var lo = 0, hi = days.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if days[mid] < range.lowerBound.rawValue { lo = mid + 1 } else { hi = mid }
        }
        let end = index(onOrBefore: range.upperBound).map { $0 + 1 } ?? 0
        guard lo < end else { return [] }
        return ArraySlice((lo..<end).map { self[$0] })
    }

    // MARK: Mutation

    /// Inserts or replaces the price for a day.
    public mutating func set(_ price: Price, on day: Day) {
        if let last = days.last, day.rawValue > last {
            days.append(day.rawValue)
            values.append(price.raw)
            return
        }
        if let i = index(onOrBefore: day) {
            if days[i] == day.rawValue {
                values[i] = price.raw
            } else {
                days.insert(day.rawValue, at: i + 1)
                values.insert(price.raw, at: i + 1)
            }
        } else {
            days.insert(day.rawValue, at: 0)
            values.insert(price.raw, at: 0)
        }
    }

    /// Merges points (any order); incoming points replace existing ones on the same day.
    /// Returns the number of days that were added or changed.
    @discardableResult
    public mutating func merge(_ points: some Sequence<PricePoint>) -> Int {
        var incoming = [Int32: Int64]()
        for p in points { incoming[p.day.rawValue] = p.price.raw }
        guard !incoming.isEmpty else { return 0 }
        var changed = 0
        var merged = [Int32: Int64](minimumCapacity: days.count + incoming.count)
        for i in days.indices { merged[days[i]] = values[i] }
        for (d, v) in incoming where merged[d] != v {
            merged[d] = v
            changed += 1
        }
        guard changed > 0 else { return 0 }
        let sorted = merged.sorted { $0.key < $1.key }
        days = sorted.map(\.key)
        values = sorted.map(\.value)
        return changed
    }

    public mutating func remove(on day: Day) {
        if let i = index(onOrBefore: day), days[i] == day.rawValue {
            days.remove(at: i)
            values.remove(at: i)
        }
    }

    public mutating func removeAll() {
        days.removeAll()
        values.removeAll()
    }

    // MARK: Codable — {"d":[…],"v":[…]}

    private enum CodingKeys: String, CodingKey { case d, v }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = try c.decode([Int32].self, forKey: .d)
        let v = try c.decode([Int64].self, forKey: .v)
        guard d.count == v.count else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "price columns differ in length")
        }
        var ascending = true
        for i in d.indices.dropFirst() where d[i] <= d[i - 1] { ascending = false; break }
        if ascending {
            days = d
            values = v
        } else {
            let sorted = Dictionary(zip(d, v), uniquingKeysWith: { _, last in last }).sorted { $0.key < $1.key }
            days = sorted.map(\.key)
            values = sorted.map(\.value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(days, forKey: .d)
        try c.encode(values, forKey: .v)
    }
}
