import Foundation

/// A single HTTP request. Only what market-data endpoints need: a URL, a method and headers.
///
/// Requests never carry cookies, credentials or any information about the user or their
/// portfolio beyond the instrument identifier that is part of the URL.
public struct HTTPRequest: Hashable, Sendable {
    public var url: URL
    public var method: String
    /// Header fields. Keys are sent as given.
    public var headers: [String: String]
    /// Timeout for the whole exchange, in seconds.
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], timeout: TimeInterval = 20) {
        self.url = url
        self.method = method
        self.headers = headers
        self.timeout = timeout
    }
}

/// The response to an ``HTTPRequest``. Any status code is delivered as a value; only transport
/// failures throw.
public struct HTTPResponse: Hashable, Sendable {
    public var status: Int
    /// Header fields with **lower-cased** names.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        var lowered = [String: String](minimumCapacity: headers.count)
        for (k, v) in headers { lowered[k.lowercased()] = v }
        self.headers = lowered
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }

    /// The body decoded as UTF-8 (lossy), mainly for diagnostics.
    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// Minimal asynchronous HTTP transport.
///
/// Implementations: ``URLSessionHTTPClient`` (real network), ``StubHTTPClient`` (in-memory, for
/// tests and previews) and ``ResilientHTTPClient`` (decorator adding retries and throttling).
public protocol HTTPClient: Sendable {
    /// Performs the request. Returns a response for every HTTP status; throws ``MarketDataError``
    /// (`.network`, `.timeout`) for transport failures and `CancellationError` when cancelled.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

extension HTTPClient {
    /// GETs `url` and returns the body of a 2xx response; other statuses are mapped to
    /// ``MarketDataError`` (`.rateLimited` for 429, `.http` otherwise).
    public func get(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> Data {
        let response = try await send(HTTPRequest(url: url, headers: headers, timeout: timeout))
        guard response.isSuccess else { throw MarketDataError(status: response.status, url: url) }
        return response.body
    }
}

/// Everything that can go wrong while fetching market data. `errorDescription` is suitable for
/// showing to the user.
public enum MarketDataError: Error, Hashable, Sendable {
    /// A URL (or URL template) could not be turned into a valid http(s) URL.
    case invalidURL(String)
    /// Transport-level failure (DNS, TLS, connection lost, offline …).
    case network(String)
    case timeout
    /// The server answered with a non-success status.
    case http(status: Int, host: String)
    /// The server keeps answering 429 Too Many Requests.
    case rateLimited(host: String)
    /// The provider does not know the symbol.
    case symbolNotFound(String)
    /// The response could not be understood.
    case malformedResponse(String)
    /// The feed configuration is incomplete or invalid (missing symbol, bad path expression …).
    case invalidConfiguration(String)
    /// `QuoteFeed.provider` names a provider that is not registered.
    case unknownProvider(String)
    /// The feed quotes in a different currency than the security.
    case currencyMismatch(expected: String, actual: String)
    /// The request is outside of what the provider can deliver.
    case unsupported(String)

    /// Maps a non-success HTTP status.
    public init(status: Int, url: URL) {
        let host = url.host ?? url.absoluteString
        self = status == 429 ? .rateLimited(host: host) : .http(status: status, host: host)
    }
}

extension MarketDataError: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .invalidURL(let s): return "Invalid URL: \(s)"
        case .network(let s): return "Network error: \(s)"
        case .timeout: return "The server did not answer in time."
        case .http(let status, let host): return "\(host) answered with HTTP \(status)."
        case .rateLimited(let host): return "\(host) is rate limiting requests. Try again later."
        case .symbolNotFound(let s): return "Unknown symbol “\(s)”."
        case .malformedResponse(let s): return "Unexpected response: \(s)"
        case .invalidConfiguration(let s): return s
        case .unknownProvider(let s): return "Unknown quote provider “\(s)”."
        case .currencyMismatch(let expected, let actual):
            return "The feed quotes in \(actual), but the security is kept in \(expected)."
        case .unsupported(let s): return s
        }
    }
}

/// User-Agent strings used by the built-in providers.
public enum UserAgent {
    /// A full desktop-browser agent, for custom setups that need one.
    public static let browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    /// The generic browser token. This is what the built-in providers send: Yahoo Finance rejects
    /// unknown clients, but answers a full browser agent with HTTP 429 when the TLS stack is not
    /// a browser's (curl, Linux) — the bare token is accepted from every stack.
    public static let minimal = "Mozilla/5.0"
}
