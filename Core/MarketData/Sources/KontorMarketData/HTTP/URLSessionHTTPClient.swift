import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ``HTTPClient`` backed by `URLSession`.
///
/// The session is ephemeral: no cookies are stored or sent, nothing is cached on disk and no
/// credentials are used, so requests cannot be correlated with the user.
public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    /// Only a session created here is invalidated when the client goes away.
    private let ownsSession: Bool

    /// - Parameter resourceTimeout: upper bound for a whole request including redirects.
    public init(resourceTimeout: TimeInterval = 60) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = resourceTimeout
        config.httpAdditionalHeaders = ["Accept": "*/*", "Accept-Language": "en-US,en;q=0.9"]
        session = URLSession(configuration: config)
        ownsSession = true
    }

    /// Uses a caller-provided session (e.g. one with a custom protocol class). The session stays
    /// the caller's: it is not invalidated when the client is released.
    public init(session: URLSession) {
        self.session = session
        ownsSession = false
    }

    deinit {
        if ownsSession { session.finishTasksAndInvalidate() }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        // Completion-handler API + continuation: available in every Foundation flavour (the async
        // `data(for:)` is missing from older swift-corelibs-foundation releases).
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                let task = session.dataTask(with: urlRequest) { data, response, error in
                    if let error {
                        continuation.resume(throwing: Self.map(error))
                    } else if let http = response as? HTTPURLResponse {
                        var headers = [String: String]()
                        for (k, v) in http.allHeaderFields {
                            if let k = k as? String { headers[k] = "\(v)" }
                        }
                        continuation.resume(returning: HTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
                    } else {
                        continuation.resume(throwing: MarketDataError.network("No HTTP response."))
                    }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    private static func map(_ error: Error) -> Error {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return MarketDataError.network(ns.localizedDescription) }
        switch ns.code {
        case NSURLErrorCancelled: return CancellationError()
        case NSURLErrorTimedOut: return MarketDataError.timeout
        default: return MarketDataError.network(ns.localizedDescription)
        }
    }
}

/// Holds the running task so that cancellation (which may arrive before or after the task was
/// created) reliably reaches it.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
