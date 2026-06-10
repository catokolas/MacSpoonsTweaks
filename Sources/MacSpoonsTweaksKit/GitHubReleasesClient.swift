import Foundation

/// Minimal slice of the GitHub Releases API. Used by
/// `NativeModuleInstaller` to resolve a module's `repo` to a versioned
/// asset URL. Unauthenticated — works on public repos only, which is
/// what the `HS_ModulesContrib-*` family is.
public protocol GitHubReleasesClient: Sendable {
    /// Fetch the latest release for `owner/repo`. Throws on network
    /// failure or non-2xx. The returned `tagName` is the GitHub release
    /// tag (e.g. `v0.1`); `assets` lists every uploaded asset with its
    /// browser-visible download URL.
    func latestRelease(repo: String) async throws -> GitHubRelease
}

public struct GitHubRelease: Sendable, Equatable {
    public let tagName: String
    public let assets:  [GitHubReleaseAsset]

    public init(tagName: String, assets: [GitHubReleaseAsset]) {
        self.tagName = tagName
        self.assets  = assets
    }
}

public struct GitHubReleaseAsset: Sendable, Equatable {
    public let name:               String
    public let browserDownloadURL: URL

    public init(name: String, browserDownloadURL: URL) {
        self.name               = name
        self.browserDownloadURL = browserDownloadURL
    }
}

public enum GitHubReleasesError: Error, CustomStringConvertible {
    case httpStatus(repo: String, code: Int)
    case malformedRepo(String)

    public var description: String {
        switch self {
        case .httpStatus(let repo, let code):
            return "GitHub Releases for \(repo) returned HTTP \(code)"
        case .malformedRepo(let s):
            return "Malformed repo identifier '\(s)' — expected owner/repo"
        }
    }
}

// MARK: - URLSession-backed implementation

public struct URLSessionGitHubReleasesClient: GitHubReleasesClient {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func latestRelease(repo: String) async throws -> GitHubRelease {
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else {
            throw GitHubReleasesError.malformedRepo(repo)
        }
        let url = URL(string:
            "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw GitHubReleasesError.httpStatus(
                repo: repo, code: http.statusCode)
        }
        let payload = try JSONDecoder().decode(_LatestPayload.self, from: data)
        let assets = payload.assets.map { asset in
            GitHubReleaseAsset(name: asset.name,
                               browserDownloadURL: asset.browser_download_url)
        }
        return GitHubRelease(tagName: payload.tag_name, assets: assets)
    }

    private struct _LatestPayload: Decodable {
        let tag_name: String
        let assets:   [_Asset]
        struct _Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
    }
}

// MARK: - Recording mock

/// Test double — returns canned releases per repo, records every call.
public final class RecordingGitHubReleasesClient:
    GitHubReleasesClient, @unchecked Sendable
{
    private let lock = NSLock()
    private var queued: [String: [GitHubRelease]] = [:]
    private var _requested: [String] = []
    private var errorToThrow: (any Error)?

    public init() {}

    public func enqueue(_ release: GitHubRelease, for repo: String) {
        lock.lock(); defer { lock.unlock() }
        queued[repo, default: []].append(release)
    }

    public func throwOnNextCall(_ error: any Error) {
        lock.lock(); defer { lock.unlock() }
        errorToThrow = error
    }

    public var requested: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requested
    }

    public func latestRelease(repo: String) async throws -> GitHubRelease {
        lock.lock()
        _requested.append(repo)
        if let err = errorToThrow {
            errorToThrow = nil
            lock.unlock()
            throw err
        }
        guard var queue = queued[repo], !queue.isEmpty else {
            lock.unlock()
            throw GitHubReleasesError.httpStatus(repo: repo, code: 404)
        }
        let next = queue.removeFirst()
        queued[repo] = queue
        lock.unlock()
        return next
    }
}
