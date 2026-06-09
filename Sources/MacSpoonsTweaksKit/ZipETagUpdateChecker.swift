import Foundation

/// Returns the upstream identity headers for a URL so callers can
/// detect a content change without downloading the body.
public protocol HTTPHeadProber: Sendable {
    func head(_ url: URL) async throws -> HTTPHeadResult
}

public struct HTTPHeadResult: Sendable, Equatable {
    public let statusCode:   Int
    public let etag:         String?
    public let lastModified: String?

    public init(statusCode: Int, etag: String?, lastModified: String?) {
        self.statusCode   = statusCode
        self.etag         = etag
        self.lastModified = lastModified
    }
}

// MARK: - URLSession-backed prober

public struct URLSessionHeadProber: HTTPHeadProber {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func head(_ url: URL) async throws -> HTTPHeadResult {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            // Non-HTTP responses shouldn't happen for the URLs we
            // hit, but surface defensively as a 0 status so callers
            // treat it as "no answer".
            return HTTPHeadResult(statusCode: 0, etag: nil, lastModified: nil)
        }
        return HTTPHeadResult(
            statusCode:   http.statusCode,
            etag:         http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }
}

// MARK: - Recording mock

/// Records every head() call and returns a configurable canned response
/// per invocation. Tests assert the requested URLs and inject ETag/
/// Last-Modified pairs.
public final class RecordingHeadProber: HTTPHeadProber, @unchecked Sendable {

    private let lock = NSLock()
    private var _requested: [URL] = []
    private var responses: [HTTPHeadResult]
    private var errorToThrow: (any Error)?

    public init(responses: [HTTPHeadResult] = []) {
        self.responses = responses
    }

    public var requested: [URL] {
        lock.lock(); defer { lock.unlock() }
        return _requested
    }

    public func throwOnNextCall(_ error: any Error) {
        lock.lock(); defer { lock.unlock() }
        errorToThrow = error
    }

    public func head(_ url: URL) async throws -> HTTPHeadResult {
        lock.lock()
        _requested.append(url)
        if let err = errorToThrow {
            errorToThrow = nil
            lock.unlock()
            throw err
        }
        let r = responses.isEmpty
            ? HTTPHeadResult(statusCode: 0, etag: nil, lastModified: nil)
            : responses.removeFirst()
        lock.unlock()
        return r
    }
}

// MARK: - Update checker

public enum ZipETagUpdateCheckerError: Error, CustomStringConvertible {
    case noETagOrLastModified(URL)
    case unexpectedStatus(URL, code: Int)

    public var description: String {
        switch self {
        case .noETagOrLastModified(let url):
            return "HEAD \(url.absoluteString) returned no ETag or Last-Modified"
        case .unexpectedStatus(let url, let code):
            return "HEAD \(url.absoluteString) → HTTP \(code)"
        }
    }
}

/// Resolves `.zipETag(URL)` strategies by issuing a HEAD against the
/// zip URL and reading the ETag (or Last-Modified, if no ETag).
///
/// `gitCommitForSubdir` strategies return `nil` (let the composite
/// route to a `GitUpdateChecker`).
public struct ZipETagUpdateChecker: UpdateChecker {

    public let prober: any HTTPHeadProber
    /// Source of "now" for the `fetchedAt` timestamp. Tests inject a
    /// fixed value for stable comparisons.
    public let clock:  @Sendable () -> Date

    public init(
        prober: any HTTPHeadProber = URLSessionHeadProber(),
        clock:  @escaping @Sendable () -> Date = { Date() }
    ) {
        self.prober = prober
        self.clock  = clock
    }

    public func checkLatest(
        strategy: UpdateCheckStrategy
    ) async throws -> InstalledRef? {
        guard case .zipETag(let url) = strategy else {
            return nil
        }

        let result = try await prober.head(url)
        guard (200..<400).contains(result.statusCode) else {
            throw ZipETagUpdateCheckerError.unexpectedStatus(
                url, code: result.statusCode)
        }

        // Prefer ETag (strong identity); fall back to Last-Modified
        // (millisecond-precision identity). Older CDNs may serve only
        // one; very old servers may serve neither.
        let identity = result.etag ?? result.lastModified
        guard let value = identity, !value.isEmpty else {
            throw ZipETagUpdateCheckerError.noETagOrLastModified(url)
        }
        return .zipETag(value: value, fetchedAt: clock())
    }
}
