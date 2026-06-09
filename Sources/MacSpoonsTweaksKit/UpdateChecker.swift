import Foundation

/// Probe for whether an upstream update is available for a given Spoon.
/// Returns the latest `InstalledRef` from upstream, or `nil` if the
/// strategy isn't supported by this implementation (let composition
/// route the request to a different checker).
public protocol UpdateChecker: Sendable {
    func checkLatest(
        strategy: UpdateCheckStrategy
    ) async throws -> InstalledRef?
}

// MARK: - Composite

/// Routes to the first child checker that knows how to handle the given
/// strategy. Lets the app stitch a `GitUpdateChecker` and (eventually)
/// a `ZipETagUpdateChecker` together behind one interface.
public struct CompositeUpdateChecker: UpdateChecker {
    public let checkers: [any UpdateChecker]

    public init(_ checkers: [any UpdateChecker]) {
        self.checkers = checkers
    }

    public func checkLatest(
        strategy: UpdateCheckStrategy
    ) async throws -> InstalledRef? {
        for checker in checkers {
            if let ref = try await checker.checkLatest(strategy: strategy) {
                return ref
            }
        }
        return nil
    }
}

// MARK: - Git impl

public enum GitUpdateCheckerError: Error, CustomStringConvertible {
    case noCommitTouchesSubdir(subdir: String, ref: String)
    case unexpectedGitOutput(String)

    public var description: String {
        switch self {
        case .noCommitTouchesSubdir(let s, let r):
            return "No commit on origin/\(r) touches '\(s)'."
        case .unexpectedGitOutput(let s):
            return "Unexpected git output: \(s)"
        }
    }
}

/// Resolves `.gitCommitForSubdir(repo, subdir, ref)` strategies by
/// maintaining a tiny shallow blobless clone of the source repo under
/// `~/Library/Caches/MacSpoonsTweaks/repos/<key>`, then asking it for
/// `git log -1 --pretty=%H origin/<ref> -- <subdir>`.
///
/// `.zipETag` strategies return `nil` (let the composite route to a
/// different checker).
public final class GitUpdateChecker: UpdateChecker, @unchecked Sendable {

    public let cacheRoot: URL
    public let runner:    any GitRunner

    /// Depth used for both the initial clone and incremental fetches.
    /// 50 commits is enough to capture the latest one touching any
    /// given subdir, in the vast majority of repos. We don't need
    /// history beyond that.
    public let cloneDepth: Int

    public init(
        cacheRoot: URL = GitUpdateChecker.defaultCacheRoot(),
        runner:    any GitRunner,
        cloneDepth: Int = 50
    ) {
        self.cacheRoot  = cacheRoot
        self.runner     = runner
        self.cloneDepth = cloneDepth
    }

    public static func defaultCacheRoot() -> URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("MacSpoonsTweaks")
            .appendingPathComponent("repos")
    }

    public func checkLatest(
        strategy: UpdateCheckStrategy
    ) async throws -> InstalledRef? {
        guard case .gitCommitForSubdir(let repo, let subdir, let ref) = strategy
        else {
            return nil   // not our job
        }

        let localRepo = try ensureCacheRoot().appendingPathComponent(
            cacheKey(for: repo))

        if !cloneAlreadyPresent(at: localRepo) {
            try await clone(repo: repo, to: localRepo, ref: ref)
        } else {
            try await fetch(at: localRepo, ref: ref)
        }

        let sha = try await latestCommit(
            at: localRepo, subdir: subdir, ref: ref)
        return .gitCommit(sha)
    }

    // MARK: - Operations

    private func ensureCacheRoot() throws -> URL {
        try FileManager.default.createDirectory(
            at: cacheRoot, withIntermediateDirectories: true)
        return cacheRoot
    }

    /// A `.git` directory inside the cache entry is the marker that the
    /// previous clone completed. If the dir exists but lacks `.git` we
    /// treat it as garbage and re-clone — a partial clone is worse than
    /// no clone (subsequent commands would error confusingly).
    private func cloneAlreadyPresent(at url: URL) -> Bool {
        let git = url.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: git.path)
    }

    private func clone(repo: URL, to dest: URL, ref: String) async throws {
        // Garbage dir from a previous failed clone? Wipe before retrying.
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        _ = try await runner.run(args: [
            "clone",
            "--filter=blob:none",        // blobless: skips file contents,
                                         //   we only ever read commit metadata
            "--no-checkout",             // skip the working-tree population
            "--depth=\(cloneDepth)",
            "--single-branch",
            "--branch=\(ref)",
            repo.absoluteString,
            dest.path,
        ], cwd: nil)
    }

    private func fetch(at repoDir: URL, ref: String) async throws {
        _ = try await runner.run(args: [
            "-C", repoDir.path,
            "fetch",
            "--depth=\(cloneDepth)",
            "origin",
            ref,
        ], cwd: nil)
    }

    private func latestCommit(
        at repoDir: URL, subdir: String, ref: String
    ) async throws -> String {
        let out = try await runner.run(args: [
            "-C", repoDir.path,
            "log", "-1", "--pretty=%H",
            "origin/\(ref)",
            "--", subdir,
        ], cwd: nil)

        let sha = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if sha.isEmpty {
            throw GitUpdateCheckerError.noCommitTouchesSubdir(
                subdir: subdir, ref: ref)
        }
        // git log %H prints a 40-char (or 64-char for SHA-256 repos)
        // hex SHA. Anything else is unexpected.
        let allHex = sha.allSatisfy { $0.isHexDigit }
        if !allHex || (sha.count != 40 && sha.count != 64) {
            throw GitUpdateCheckerError.unexpectedGitOutput(sha)
        }
        return sha
    }

    // MARK: - Internals

    /// Stable, readable cache-directory name for a repo URL. Strips the
    /// scheme so URLs without a trailing slash don't bleed special
    /// characters into the filename, then maps `/` and `:` to `-`.
    /// Example: `https://github.com/catokolas/HS_SpoonsContrib` →
    /// `github.com-catokolas-HS_SpoonsContrib`.
    public func cacheKey(for url: URL) -> String {
        var s = url.absoluteString
        if s.hasPrefix("https://") { s = String(s.dropFirst(8)) }
        if s.hasPrefix("http://")  { s = String(s.dropFirst(7)) }
        if s.hasSuffix("/")        { s = String(s.dropLast())   }
        if s.hasSuffix(".git")     { s = String(s.dropLast(4))  }
        return s.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: " ", with: "-")
    }
}
