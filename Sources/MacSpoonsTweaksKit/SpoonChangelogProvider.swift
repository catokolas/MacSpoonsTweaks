import Foundation

/// Resolves the "what's changed?" preview shown when a Spoon has an
/// update available. Two strategies feed two implementations:
///   * `.gitCommitForSubdir` → `GitSpoonChangelogProvider` walks a
///     shallow clone (the same cache `GitUpdateChecker` maintains) and
///     emits `git log installed..latest -- subdir`.
///   * `.zipETag` → `UpstreamCommitsAPIChangelogProvider` hits the
///     GitHub Commits API for the Spoon's subdir. Marked as
///     `precise = false` since zip ETags don't pin a commit.
public protocol SpoonChangelogProvider: Sendable {
    func changelog(
        for entry:    SpoonCatalogEntry,
        strategy:     UpdateCheckStrategy,
        installed:    InstalledRef?,
        latest:       InstalledRef?
    ) async throws -> SpoonChangelog
}

public enum SpoonChangelogError: Error, CustomStringConvertible {
    case missingLatestRef
    case unsupportedStrategy
    case httpStatus(URL, Int)
    case malformedAPIResponse(String)

    public var description: String {
        switch self {
        case .missingLatestRef:
            return "No update info yet — try refreshing first."
        case .unsupportedStrategy:
            return "This Spoon's catalog source doesn't support a change preview."
        case .httpStatus(let url, let code):
            return "HTTP \(code) from \(url.host ?? url.absoluteString)"
        case .malformedAPIResponse(let msg):
            return "Malformed GitHub API response: \(msg)"
        }
    }
}

// MARK: - Composite

public struct CompositeSpoonChangelogProvider: SpoonChangelogProvider {
    public let providers: [any SpoonChangelogProvider]

    public init(_ providers: [any SpoonChangelogProvider]) {
        self.providers = providers
    }

    public func changelog(
        for entry:    SpoonCatalogEntry,
        strategy:     UpdateCheckStrategy,
        installed:    InstalledRef?,
        latest:       InstalledRef?
    ) async throws -> SpoonChangelog {
        var lastError: Error?
        for provider in providers {
            do {
                return try await provider.changelog(
                    for: entry, strategy: strategy,
                    installed: installed, latest: latest)
            } catch SpoonChangelogError.unsupportedStrategy {
                continue
            } catch {
                lastError = error
            }
        }
        throw lastError ?? SpoonChangelogError.unsupportedStrategy
    }
}

// MARK: - Git impl

/// Walks the shallow clone `GitUpdateChecker` already maintains and
/// extracts `git log a..b -- subdir`. Fetches before logging so the
/// blobless clone has enough history for the range.
public final class GitSpoonChangelogProvider:
    SpoonChangelogProvider, @unchecked Sendable
{
    public let runner:     any GitRunner
    public let cacheRoot:  URL
    public let maxCommits: Int

    public init(
        runner:     any GitRunner,
        cacheRoot:  URL = GitUpdateChecker.defaultCacheRoot(),
        maxCommits: Int = 50
    ) {
        self.runner     = runner
        self.cacheRoot  = cacheRoot
        self.maxCommits = maxCommits
    }

    public func changelog(
        for entry:    SpoonCatalogEntry,
        strategy:     UpdateCheckStrategy,
        installed:    InstalledRef?,
        latest:       InstalledRef?
    ) async throws -> SpoonChangelog {
        guard case .gitCommitForSubdir(let repo, let subdir, let ref) = strategy
        else { throw SpoonChangelogError.unsupportedStrategy }
        guard case .gitCommit(let latestSHA)? = latest, !latestSHA.isEmpty
        else { throw SpoonChangelogError.missingLatestRef }

        let localRepo = cacheRoot
            .appendingPathComponent(cacheKey(for: repo))
        // Best-effort fetch: if the clone hasn't been created yet,
        // `GitUpdateChecker` will catch it on the next refresh — we
        // can't kick a fresh clone here without re-implementing its
        // logic. If fetch fails we proceed; git log may still work
        // off the existing depth.
        _ = try? await runner.run(args: [
            "-C", localRepo.path,
            "fetch", "--depth=\(maxCommits)", "origin", ref,
        ], cwd: nil)

        // Pick the range. If `installed` isn't a real SHA we degrade
        // to "last N commits touching the subdir".
        let installedSHA: String?
        if case .gitCommit(let s)? = installed,
           isRealSHA(s) {
            installedSHA = s
        } else {
            installedSHA = nil
        }

        let pretty = "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e"
        var args = ["-C", localRepo.path, "log",
                    "-\(maxCommits)", pretty]
        if let installed = installedSHA {
            args.append("\(installed)..\(latestSHA)")
        } else {
            args.append(latestSHA)
        }
        args.append(contentsOf: ["--", subdir])

        let raw = try await runner.run(args: args, cwd: nil)
        let commits = Self.parse(rawLog: raw,
                                 repoBaseURL: githubBaseURL(from: repo))

        let compareURL: URL? = installedSHA.flatMap { i in
            githubBaseURL(from: repo).map { base in
                URL(string: "\(base)/compare/\(i)...\(latestSHA)")
            } ?? nil
        } ?? (githubBaseURL(from: repo).flatMap { base in
            URL(string: "\(base)/commits/\(ref)")
        })

        let precise = installedSHA != nil
        let note: String? = precise ? nil :
            "Installed version isn't pinned to a commit yet; recent commits touching this Spoon are shown."

        return SpoonChangelog(
            commits:    commits,
            compareURL: compareURL,
            precise:    precise,
            note:       note)
    }

    // MARK: - Parsing

    /// Parse `--pretty=format:%H\x1f%s\x1f%an\x1f%aI\x1e` output.
    /// Records are RS-separated (`\x1e`); fields within a record are
    /// US-separated (`\x1f`).
    static func parse(rawLog: String, repoBaseURL: String?) -> [SpoonCommit] {
        let trimmed = rawLog.trimmingCharacters(
            in: CharacterSet(charactersIn: "\u{1e}\n"))
        if trimmed.isEmpty { return [] }
        var commits: [SpoonCommit] = []
        for record in trimmed.split(separator: "\u{1e}",
                                    omittingEmptySubsequences: true) {
            let cleaned = String(record).trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = cleaned.split(separator: "\u{1f}",
                                       omittingEmptySubsequences: false)
                                 .map(String.init)
            guard fields.count >= 4 else { continue }
            let sha = fields[0]
            let subject = fields[1]
            let author  = fields[2]
            guard let date = isoDate(fields[3]) else { continue }
            let url = repoBaseURL.flatMap {
                URL(string: "\($0)/commit/\(sha)")
            } ?? URL(string: "https://github.com/")!
            commits.append(SpoonCommit(
                sha: sha, subject: subject,
                author: author, date: date, url: url))
        }
        return commits
    }

    // MARK: - Helpers

    private func isRealSHA(_ s: String) -> Bool {
        let hex = s.allSatisfy { $0.isHexDigit }
        return hex && (s.count == 40 || s.count == 64)
    }

    /// Mirrors `GitUpdateChecker.cacheKey(for:)` — kept as a private
    /// duplicate so we don't depend on its instance.
    private func cacheKey(for url: URL) -> String {
        var s = url.absoluteString
        if s.hasPrefix("https://") { s = String(s.dropFirst(8)) }
        if s.hasPrefix("http://")  { s = String(s.dropFirst(7)) }
        if s.hasSuffix("/")        { s = String(s.dropLast())   }
        if s.hasSuffix(".git")     { s = String(s.dropLast(4))  }
        return s.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: " ", with: "-")
    }

    /// "https://github.com/owner/repo" with no trailing slash. Returns
    /// nil for non-github URLs so callers can fall back gracefully.
    private func githubBaseURL(from repo: URL) -> String? {
        guard repo.host?.hasSuffix("github.com") == true
        else { return nil }
        var s = repo.absoluteString
        if s.hasSuffix("/")    { s = String(s.dropLast()) }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        return s
    }

    private static func isoDate(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: raw)
    }
}

// MARK: - Upstream Commits API impl

/// Resolves `.zipETag` strategies by hitting GitHub's Commits API for
/// the Spoon's subdir. Marks the result as imprecise — zip ETags
/// don't pin a commit, so we can't bound the range.
public final class UpstreamCommitsAPIChangelogProvider:
    SpoonChangelogProvider, @unchecked Sendable
{
    public let session:    URLSession
    public let perPage:    Int

    public init(session: URLSession = .shared, perPage: Int = 20) {
        self.session = session
        self.perPage = perPage
    }

    public func changelog(
        for entry:    SpoonCatalogEntry,
        strategy:     UpdateCheckStrategy,
        installed:    InstalledRef?,
        latest:       InstalledRef?
    ) async throws -> SpoonChangelog {
        guard case .zipETag(let zipURL) = strategy else {
            throw SpoonChangelogError.unsupportedStrategy
        }
        guard let parts = ownerRepoAndPath(from: zipURL) else {
            throw SpoonChangelogError.unsupportedStrategy
        }
        let (owner, repo, subdir) = parts
        let apiURL = URL(string:
            "https://api.github.com/repos/\(owner)/\(repo)/commits"
            + "?path=\(subdir)&per_page=\(perPage)")!

        var req = URLRequest(url: apiURL)
        req.setValue("application/vnd.github+json",
                     forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28",
                     forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw SpoonChangelogError.httpStatus(apiURL, http.statusCode)
        }
        let commits = try Self.parse(
            json: data, owner: owner, repo: repo)

        let webPage = URL(string:
            "https://github.com/\(owner)/\(repo)/commits/master/\(subdir)")
        let note = "Upstream Spoons don't carry version info; the last "
                 + "\(perPage) commits touching this Spoon are shown. "
                 + "Your installed version may pre-date or post-date "
                 + "some of them."
        return SpoonChangelog(
            commits:    commits,
            compareURL: webPage,
            precise:    false,
            note:       note)
    }

    // MARK: - Parsing

    static func parse(json data: Data, owner: String, repo: String) throws
        -> [SpoonCommit]
    {
        guard let arr = try JSONSerialization.jsonObject(with: data)
            as? [[String: Any]]
        else {
            throw SpoonChangelogError.malformedAPIResponse(
                "expected top-level array")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var commits: [SpoonCommit] = []
        for obj in arr {
            guard let sha = obj["sha"] as? String,
                  let commit = obj["commit"] as? [String: Any],
                  let message = commit["message"] as? String,
                  let author  = commit["author"] as? [String: Any],
                  let name    = author["name"] as? String,
                  let dateStr = author["date"] as? String,
                  let date    = formatter.date(from: dateStr)
            else { continue }
            let subject = message
                .split(separator: "\n", maxSplits: 1,
                       omittingEmptySubsequences: false)
                .first.map(String.init) ?? message
            let url = (obj["html_url"] as? String)
                .flatMap(URL.init(string:))
                ?? URL(string:
                    "https://github.com/\(owner)/\(repo)/commit/\(sha)")!
            commits.append(SpoonCommit(
                sha: sha,
                subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                author:  name,
                date:    date,
                url:     url))
        }
        return commits
    }

    /// Extract `(owner, repo, path)` from the upstream zip URL the
    /// strategy carries. Only handles the
    /// `github.com/<owner>/<repo>/raw/<branch>/<path>` shape that
    /// `HammerspoonOfficialSource` emits.
    private func ownerRepoAndPath(from url: URL) -> (String, String, String)? {
        var comps = url.pathComponents
        comps.removeAll { $0 == "/" }
        // [owner, repo, "raw", branch, path components..., "<Name>.spoon.zip"]
        guard comps.count >= 5,
              comps[2] == "raw" else { return nil }
        let owner = comps[0]
        let repo  = comps[1]
        // Drop owner/repo/raw/branch and the trailing "<Name>.spoon.zip".
        // Keep the in-between components, then append the directory name.
        let pathParts = Array(comps[4..<(comps.count - 1)])
        let last = comps.last ?? ""
        guard last.hasSuffix(".zip") else { return nil }
        let dir = String(last.dropLast(4))
        let path = (pathParts + [dir]).joined(separator: "/")
        return (owner, repo, path)
    }
}
