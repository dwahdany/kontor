import Foundation
import KontorModel
@testable import KontorMarketData

func fixture(_ name: String) -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
          let data = try? Data(contentsOf: url) else {
        fatalError("missing fixture \(name)")
    }
    return data
}

func day(_ iso: String) -> Day {
    guard let d = Day(iso: iso) else { fatalError("bad day \(iso)") }
    return d
}

func point(_ iso: String, _ price: Double) -> PricePoint {
    PricePoint(day: day(iso), price: Price(price))
}

/// Virtual time: sleeping advances the clock instantly and is recorded.
final class ManualClock: MarketDataClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var recorded: [TimeInterval] = []
    private let advances: Bool

    /// - Parameter advances: whether sleeping moves the clock (false = time stands still).
    init(advances: Bool = true) {
        self.advances = advances
    }

    func now() -> TimeInterval { lock.withLock { time } }
    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock {
            if advances { time += seconds }
            recorded.append(seconds)
        }
    }
    var sleeps: [TimeInterval] { lock.withLock { recorded } }
}

/// Scriptable quote provider that records what it was asked for.
final class FakeProvider: QuoteProvider, @unchecked Sendable {
    typealias Behavior = @Sendable (QuoteRequest) async throws -> QuoteHistory

    let id: String
    private let behavior: Behavior
    private let lock = NSLock()
    private var log: [QuoteRequest] = []
    private var inFlight = 0
    private var peak = 0

    init(id: String = "fake", behavior: @escaping Behavior) {
        self.id = id
        self.behavior = behavior
    }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(id: id, name: "Fake", summary: "", symbol: ProviderOption(key: "symbol", label: "Symbol"))
    }

    var requests: [QuoteRequest] { lock.withLock { log } }
    var peakConcurrency: Int { lock.withLock { peak } }

    func history(_ request: QuoteRequest) async throws -> QuoteHistory {
        lock.withLock {
            log.append(request)
            inFlight += 1
            peak = max(peak, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        return try await behavior(request)
    }
}

/// Scriptable rate provider.
final class FakeRates: ExchangeRateProvider, @unchecked Sendable {
    let baseCurrency = "EUR"
    private let behavior: @Sendable ([RateRequest]) async throws -> RateBatch
    private let lock = NSLock()
    private var log: [[RateRequest]] = []

    init(_ behavior: @escaping @Sendable ([RateRequest]) async throws -> RateBatch) {
        self.behavior = behavior
    }

    var requests: [[RateRequest]] { lock.withLock { log } }

    func rates(for requests: [RateRequest]) async throws -> RateBatch {
        lock.withLock { log.append(requests) }
        return try await behavior(requests)
    }
}

/// Collects values from concurrent callbacks.
final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

func security(_ name: String, symbol: String, provider: String = "fake", currency: String = "EUR",
              prices: [PricePoint] = [], updatedAt: Date? = nil) -> Security {
    Security(name: name, currency: currency, ticker: symbol, feed: QuoteFeed(provider: provider, symbol: symbol),
             prices: PriceSeries(prices), updatedAt: updatedAt)
}

func date(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    guard let d = formatter.date(from: iso) else { fatalError("bad date \(iso)") }
    return d
}
