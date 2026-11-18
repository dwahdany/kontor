import Foundation

/// In-memory ``HTTPClient`` for tests and previews: answers from registered routes and records
/// every request.
///
/// ```swift
/// let http = StubHTTPClient()
/// http.on("finance/chart/AAPL", body: fixtureData)
/// http.on("eurofxref-daily.xml", responses: [.init(status: 503), .init(status: 200, body: xml)])
/// ```
/// Routes are matched by substring of the absolute URL, first registered match wins. A route
/// with several responses plays them in order and repeats the last one. Unmatched requests get
/// a 404.
public final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    private struct Route {
        var pattern: String
        var responses: [HTTPResponse]
        var handler: Handler?
        var hits = 0
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var log: [HTTPRequest] = []

    public init() {}

    /// Answers URLs containing `pattern` with `body` and `status`.
    public func on(_ pattern: String, status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        on(pattern, responses: [HTTPResponse(status: status, headers: headers, body: body)])
    }

    /// Answers URLs containing `pattern` with a UTF-8 string body.
    public func on(_ pattern: String, status: Int = 200, text: String) {
        on(pattern, status: status, body: Data(text.utf8))
    }

    /// Answers successive requests with successive responses (the last one repeats).
    public func on(_ pattern: String, responses: [HTTPResponse]) {
        precondition(!responses.isEmpty)
        lock.withLock { routes.append(Route(pattern: pattern, responses: responses, handler: nil)) }
    }

    /// Answers URLs containing `pattern` by running `handler` (may suspend or throw).
    public func on(_ pattern: String, handler: @escaping Handler) {
        lock.withLock { routes.append(Route(pattern: pattern, responses: [], handler: handler)) }
    }

    /// All requests received so far, in arrival order.
    public var requests: [HTTPRequest] { lock.withLock { log } }

    /// Absolute URL strings of all requests received so far.
    public var requestedURLs: [String] { requests.map(\.url.absoluteString) }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let action: (HTTPResponse?, Handler?) = lock.withLock {
            log.append(request)
            let url = request.url.absoluteString
            guard let i = routes.firstIndex(where: { url.contains($0.pattern) }) else { return (nil, nil) }
            if let handler = routes[i].handler { return (nil, handler) }
            let response = routes[i].responses[min(routes[i].hits, routes[i].responses.count - 1)]
            routes[i].hits += 1
            return (response, nil)
        }
        if let handler = action.1 { return try await handler(request) }
        return action.0 ?? HTTPResponse(status: 404, body: Data("no stub for \(request.url.absoluteString)".utf8))
    }
}
