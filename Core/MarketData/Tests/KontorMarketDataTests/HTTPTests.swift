import Foundation
import Testing
@testable import KontorMarketData

@Suite struct HTTPTests {
    let url = URL(string: "https://api.example.com/data")!

    @Test func stubMatchesRoutesAndRecordsRequests() async throws {
        let http = StubHTTPClient()
        http.on("/data", text: "hello")
        let body = try await http.get(url, headers: ["X-Test": "1"])
        #expect(String(decoding: body, as: UTF8.self) == "hello")
        #expect(http.requestedURLs == ["https://api.example.com/data"])
        #expect(http.requests[0].headers == ["X-Test": "1"])

        let missing = try await http.send(HTTPRequest(url: URL(string: "https://other.example.com/x")!))
        #expect(missing.status == 404)
    }

    @Test func getMapsStatusCodesToErrors() async {
        let http = StubHTTPClient()
        http.on("/limited", status: 429)
        http.on("/broken", status: 500)
        await #expect(throws: MarketDataError.rateLimited(host: "api.example.com")) {
            _ = try await http.get(URL(string: "https://api.example.com/limited")!)
        }
        await #expect(throws: MarketDataError.http(status: 500, host: "api.example.com")) {
            _ = try await http.get(URL(string: "https://api.example.com/broken")!)
        }
    }

    @Test func responseHeadersAreLowercased() {
        let response = HTTPResponse(status: 200, headers: ["Retry-After": "3", "Content-Type": "text/csv"])
        #expect(response.headers["retry-after"] == "3")
        #expect(response.headers["content-type"] == "text/csv")
    }

    @Test func retriesWithBackoffAndHonorsRetryAfter() async throws {
        let stub = StubHTTPClient()
        stub.on("/data", responses: [
            HTTPResponse(status: 503),
            HTTPResponse(status: 429, headers: ["Retry-After": "3"]),
            HTTPResponse(status: 200, body: Data("ok".utf8)),
        ])
        let clock = ManualClock()
        let http = ResilientHTTPClient(stub, retry: RetryPolicy(maxAttempts: 4, baseDelay: 0.5, jitter: 0), throttle: .none, clock: clock)
        let response = try await http.send(HTTPRequest(url: url))
        #expect(response.status == 200)
        #expect(stub.requests.count == 3)
        #expect(clock.sleeps == [0.5, 3])
    }

    @Test func givesUpAfterMaxAttemptsAndReturnsLastResponse() async throws {
        let stub = StubHTTPClient()
        stub.on("/data", status: 500)
        let clock = ManualClock()
        let http = ResilientHTTPClient(stub, retry: RetryPolicy(maxAttempts: 3, baseDelay: 0.5, jitter: 0), throttle: .none, clock: clock)
        let response = try await http.send(HTTPRequest(url: url))
        #expect(response.status == 500)
        #expect(stub.requests.count == 3)
        #expect(clock.sleeps == [0.5, 1.0])
    }

    @Test func doesNotRetryClientErrors() async throws {
        let stub = StubHTTPClient()
        stub.on("/data", status: 404)
        let clock = ManualClock()
        let http = ResilientHTTPClient(stub, retry: RetryPolicy(maxAttempts: 5, jitter: 0), throttle: .none, clock: clock)
        #expect(try await http.send(HTTPRequest(url: url)).status == 404)
        #expect(stub.requests.count == 1)
        #expect(clock.sleeps.isEmpty)
    }

    @Test func retriesTransportErrors() async throws {
        let stub = StubHTTPClient()
        let attempts = Collector<Int>()
        stub.on("/data") { _ in
            attempts.add(1)
            if attempts.all.count < 3 { throw MarketDataError.network("connection lost") }
            return HTTPResponse(status: 200)
        }
        let clock = ManualClock()
        let http = ResilientHTTPClient(stub, retry: RetryPolicy(maxAttempts: 3, baseDelay: 1, jitter: 0), throttle: .none, clock: clock)
        #expect(try await http.send(HTTPRequest(url: url)).status == 200)
        #expect(clock.sleeps == [1, 2])

        let failing = StubHTTPClient()
        failing.on("/data") { _ in throw MarketDataError.timeout }
        let giveUp = ResilientHTTPClient(failing, retry: RetryPolicy(maxAttempts: 2, jitter: 0), throttle: .none, clock: ManualClock())
        await #expect(throws: MarketDataError.timeout) { _ = try await giveUp.send(HTTPRequest(url: url)) }
        #expect(failing.requests.count == 2)
    }

    @Test func backoffIsCappedAndJitterStaysInBounds() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 1, maxDelay: 5, jitter: 0)
        #expect(policy.delay(retry: 1) == 1)
        #expect(policy.delay(retry: 2) == 2)
        #expect(policy.delay(retry: 3) == 4)
        #expect(policy.delay(retry: 4) == 5)
        #expect(policy.delay(retry: 1, retryAfter: "120") == 5)
        #expect(policy.delay(retry: 2, retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT") == 2)
        let jittered = RetryPolicy(baseDelay: 1, jitter: 0.2)
        for _ in 0..<50 { #expect((0.8...1.2).contains(jittered.delay(retry: 1))) }
    }

    @Test func throttlesRequestsPerHost() async throws {
        let stub = StubHTTPClient()
        stub.on("example.com", status: 200)
        let clock = ManualClock()
        let http = ResilientHTTPClient(stub, retry: .none, throttle: ThrottlePolicy(defaultInterval: 0, hostIntervals: ["example.com": 1]), clock: clock)
        let a = URL(string: "https://api.example.com/1")!
        _ = try await http.send(HTTPRequest(url: a))
        #expect(clock.sleeps.isEmpty)
        _ = try await http.send(HTTPRequest(url: a))
        _ = try await http.send(HTTPRequest(url: a))
        #expect(clock.sleeps == [1, 1])
        // Another host is not held back.
        _ = try await http.send(HTTPRequest(url: URL(string: "https://elsewhere.org/1")!))
        #expect(clock.sleeps == [1, 1])
    }

    @Test func concurrentRequestsToOneHostAreSpacedOut() async throws {
        let stub = StubHTTPClient()
        stub.on("example.com", status: 200)
        let clock = ManualClock(advances: false)
        let http = ResilientHTTPClient(stub, retry: .none, throttle: ThrottlePolicy(defaultInterval: 1), clock: clock)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<4 {
                group.addTask { _ = try await http.send(HTTPRequest(url: URL(string: "https://example.com/\(i)")!)) }
            }
            try await group.waitForAll()
        }
        #expect(stub.requests.count == 4)
        // Slots 0, 1, 2, 3 seconds after the first request: three waits, each at least one interval.
        #expect(clock.sleeps.sorted() == [1, 2, 3])
    }

    @Test func throttlePolicyMatchesSubdomains() {
        let policy = ThrottlePolicy.standard
        #expect(policy.interval(for: "query1.finance.yahoo.com") == 0.04)
        #expect(policy.interval(for: "www.ecb.europa.eu") == 0.2)
        #expect(policy.interval(for: "api.coingecko.com") == 2.2)
        #expect(policy.interval(for: "example.com") == 0.1)
    }

    @Test func errorsHaveReadableDescriptions() {
        #expect(MarketDataError.symbolNotFound("XYZ").localizedDescription == "Unknown symbol “XYZ”.")
        #expect(MarketDataError.currencyMismatch(expected: "EUR", actual: "USD").description == "The feed quotes in USD, but the security is kept in EUR.")
        #expect(MarketDataError(status: 429, url: url) == .rateLimited(host: "api.example.com"))
    }
}
