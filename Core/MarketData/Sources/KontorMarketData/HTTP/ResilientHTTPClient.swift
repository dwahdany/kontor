import Foundation

/// Time source used for throttling and back-off; injectable so tests can run on virtual time.
public protocol MarketDataClock: Sendable {
    /// Monotonic "now" in seconds (arbitrary origin).
    func now() -> TimeInterval
    /// Suspends for `seconds`; throws `CancellationError` when the task is cancelled.
    func sleep(seconds: TimeInterval) async throws
}

/// The real clock.
public struct SystemClock: MarketDataClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        // Clamped to a day: no pacing or back-off delay is longer, and a runaway value
        // (infinity from a misconfigured policy) must not trap in the conversion.
        try await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000))
    }
}

/// When and how often failed requests are repeated.
public struct RetryPolicy: Hashable, Sendable {
    /// Total number of attempts including the first one (1 = never retry).
    public var maxAttempts: Int
    /// Delay before the first retry; doubles with every further retry.
    public var baseDelay: TimeInterval
    /// Upper bound for a single delay (also caps `Retry-After`).
    public var maxDelay: TimeInterval
    /// Random spread applied to computed delays, as a fraction (0.2 = ±20 %). 0 = deterministic.
    public var jitter: Double
    /// Whether transport errors (timeouts, dropped connections) are retried like 5xx.
    public var retriesTransportErrors: Bool

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 8, jitter: Double = 0.2, retriesTransportErrors: Bool = true) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.retriesTransportErrors = retriesTransportErrors
    }

    public static let none = RetryPolicy(maxAttempts: 1)

    /// 429 and 5xx are worth repeating; everything else is final.
    public func shouldRetry(status: Int) -> Bool { status == 429 || (500..<600).contains(status) }

    /// Delay before retry number `retry` (1-based). A `Retry-After` header given in seconds wins
    /// over exponential back-off.
    public func delay(retry: Int, retryAfter: String? = nil) -> TimeInterval {
        if let retryAfter, let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return min(seconds, maxDelay)
        }
        let exponential = baseDelay * pow(2, Double(max(0, retry - 1)))
        let spread = jitter > 0 ? 1 + Double.random(in: -jitter...jitter) : 1
        return min(exponential * spread, maxDelay)
    }
}

/// Minimum spacing between requests to the same host.
public struct ThrottlePolicy: Hashable, Sendable {
    /// Spacing for hosts without an override, in seconds.
    public var defaultInterval: TimeInterval
    /// Per-host spacing; a key matches the host itself and all of its subdomains.
    public var hostIntervals: [String: TimeInterval]

    public init(defaultInterval: TimeInterval = 0.05, hostIntervals: [String: TimeInterval] = [:]) {
        self.defaultInterval = defaultInterval
        self.hostIntervals = hostIntervals
    }

    /// Conservative spacing for the built-in providers.
    public static let standard = ThrottlePolicy(
        defaultInterval: 0.1,
        hostIntervals: ["finance.yahoo.com": 0.04, "api.coingecko.com": 2.2, "ecb.europa.eu": 0.2]
    )
    public static let none = ThrottlePolicy(defaultInterval: 0)

    /// The spacing for `host`: an exact entry, else the most specific (longest) parent domain
    /// with an entry, else the default.
    public func interval(for host: String) -> TimeInterval {
        if let exact = hostIntervals[host] { return exact }
        var best: (length: Int, interval: TimeInterval)?
        for (suffix, interval) in hostIntervals where host.hasSuffix("." + suffix) && suffix.count > (best?.length ?? -1) {
            best = (suffix.count, interval)
        }
        return best?.interval ?? defaultInterval
    }
}

/// Decorates an ``HTTPClient`` with per-host request spacing and retry with exponential back-off
/// on 429 / 5xx / transport errors.
///
/// After the last attempt the final response is returned as is (or the final transport error is
/// thrown), so callers map errors exactly as they would without the decorator.
public final class ResilientHTTPClient: HTTPClient {
    private let base: any HTTPClient
    private let retry: RetryPolicy
    private let throttle: ThrottlePolicy
    private let clock: any MarketDataClock
    private let schedule = HostSchedule()

    public init(
        _ base: any HTTPClient, retry: RetryPolicy = RetryPolicy(), throttle: ThrottlePolicy = .standard,
        clock: any MarketDataClock = SystemClock()
    ) {
        self.base = base
        self.retry = retry
        self.throttle = throttle
        self.clock = clock
    }

    /// The production stack: `URLSession` + standard throttling + three attempts.
    public static func standard() -> ResilientHTTPClient { ResilientHTTPClient(URLSessionHTTPClient()) }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let host = request.url.host?.lowercased() ?? ""
        let interval = throttle.interval(for: host)
        var attempt = 1
        while true {
            try Task.checkCancellation()
            if interval > 0 {
                let slot = await schedule.reserve(host: host, interval: interval, now: clock.now())
                if slot.wait > 0 {
                    do {
                        try await clock.sleep(seconds: slot.wait)
                    } catch {
                        // Cancelled while queueing: hand the slot back, or the requests of the
                        // next update would wait behind a queue that no longer exists.
                        await schedule.release(slot, host: host)
                        throw error
                    }
                }
            }
            do {
                let response = try await base.send(request)
                guard retry.shouldRetry(status: response.status), attempt < retry.maxAttempts else { return response }
                try await clock.sleep(seconds: retry.delay(retry: attempt, retryAfter: response.headers["retry-after"]))
            } catch let error as MarketDataError {
                guard retry.retriesTransportErrors, attempt < retry.maxAttempts, error == .timeout || error.isTransport else {
                    throw error
                }
                try await clock.sleep(seconds: retry.delay(retry: attempt))
            }
            attempt += 1
        }
    }
}

extension MarketDataError {
    fileprivate var isTransport: Bool {
        if case .network = self { return true }
        return false
    }
}

/// Hands out per-host time slots: each request to a host starts at least `interval` after the
/// previous one, regardless of how many tasks ask concurrently. Slots of waiters that give up
/// (cancellation) are returned, so an abandoned queue does not delay later requests.
private actor HostSchedule {
    /// A reserved slot: `wait` seconds from the moment of the reservation.
    struct Slot: Sendable {
        var wait: TimeInterval
        fileprivate var epoch: Int
        fileprivate var index: Int
    }

    /// Slots of one host are `origin + index × interval`; `count` is the next free index.
    private struct Queue {
        var origin: TimeInterval
        var interval: TimeInterval
        var count = 0
        /// Identifies the current `origin`; slots of an earlier epoch are history.
        var epoch = 0
        /// Returned slots that are not (yet) at the end of the queue.
        var released = Set<Int>()
    }

    private var queues: [String: Queue] = [:]

    /// Reserves the next slot of `host`.
    func reserve(host: String, interval: TimeInterval, now: TimeInterval) -> Slot {
        var queue = queues[host] ?? Queue(origin: now, interval: interval)
        let next = queue.origin + Double(queue.count) * queue.interval
        if queue.count == 0 || now >= next || queue.interval != interval {
            // The queue has drained (or the policy changed): start over from now.
            queue = Queue(origin: max(now, queue.count == 0 ? now : next), interval: interval, count: 0, epoch: queue.epoch + 1)
        }
        let slot = Slot(wait: max(0, queue.origin + Double(queue.count) * interval - now), epoch: queue.epoch, index: queue.count)
        queue.count += 1
        queues[host] = queue
        return slot
    }

    /// Returns a slot that will not be used. Trailing free slots are handed out again; a free
    /// slot in the middle of the queue simply stays empty.
    func release(_ slot: Slot, host: String) {
        guard var queue = queues[host], queue.epoch == slot.epoch, slot.index < queue.count else { return }
        queue.released.insert(slot.index)
        // The first slot of an epoch was taken without waiting and is never released, so the
        // queue cannot shrink to before its origin.
        while queue.count > 1, queue.released.remove(queue.count - 1) != nil { queue.count -= 1 }
        queues[host] = queue
    }
}
