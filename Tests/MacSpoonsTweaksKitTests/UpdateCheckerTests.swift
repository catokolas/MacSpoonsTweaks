import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("GitUpdateChecker")
struct GitUpdateCheckerTests {

    // MARK: - Command construction (mocked runner)

    @Test
    func firstCheckClonesRepoWhenCacheEmpty() async throws {
        let cache = try makeTmpCache()
        defer { cleanup(cache) }
        // The runner produces a 40-char hex SHA for the log call (third).
        // Clone and fetch don't have stdout we care about.
        let sha = String(repeating: "a", count: 40)
        let runner = RecordingGitRunner(outputs: ["", sha])
        let checker = GitUpdateChecker(cacheRoot: cache, runner: runner)

        let ref = try await checker.checkLatest(strategy: .gitCommitForSubdir(
            repo: URL(string: "https://github.com/catokolas/HS_SpoonsContrib")!,
            subdir: "FocusFollowsMouse.spoon",
            ref: "main"))

        #expect(ref == .gitCommit(sha))
        let calls = runner.calls
        #expect(calls.count == 2, "expected clone + log, got \(calls.count)")

        // Call 1: clone.
        #expect(calls[0].args.first == "clone")
        #expect(calls[0].args.contains("--filter=blob:none"))
        #expect(calls[0].args.contains("--no-checkout"))
        #expect(calls[0].args.contains("--branch=main"))
        #expect(calls[0].args.contains(
            "https://github.com/catokolas/HS_SpoonsContrib"))

        // Call 2: log -1 --pretty=%H origin/main -- <subdir>.
        #expect(calls[1].args.first == "-C")
        #expect(calls[1].args.contains("log"))
        #expect(calls[1].args.contains("-1"))
        #expect(calls[1].args.contains("--pretty=%H"))
        #expect(calls[1].args.contains("origin/main"))
        #expect(calls[1].args.contains("FocusFollowsMouse.spoon"))
    }

    @Test
    func subsequentCheckFetchesInsteadOfReCloning() async throws {
        let cache = try makeTmpCache()
        defer { cleanup(cache) }
        // Plant a fake clone — checker detects it via .git presence.
        let repoURL = URL(string: "https://github.com/catokolas/HS_SpoonsContrib")!
        let checker = GitUpdateChecker(
            cacheRoot: cache, runner: RecordingGitRunner())  // dummy
        let clone = cache.appendingPathComponent(checker.cacheKey(for: repoURL))
        try FileManager.default.createDirectory(
            at: clone.appendingPathComponent(".git"),
            withIntermediateDirectories: true)

        let sha = String(repeating: "f", count: 40)
        let runner = RecordingGitRunner(outputs: ["", sha])
        let checker2 = GitUpdateChecker(cacheRoot: cache, runner: runner)

        _ = try await checker2.checkLatest(strategy: .gitCommitForSubdir(
            repo: repoURL,
            subdir: "FocusFollowsMouse.spoon",
            ref: "main"))

        let calls = runner.calls
        #expect(calls.count == 2)
        #expect(calls[0].args.first == "-C")
        #expect(calls[0].args.contains("fetch"))
        #expect(calls[0].args.contains("origin"))
        #expect(calls[0].args.contains("main"))
        // The log call still goes through as call 2.
        #expect(calls[1].args.contains("log"))
    }

    @Test
    func returnsNilForUnsupportedStrategy() async throws {
        let cache = try makeTmpCache()
        defer { cleanup(cache) }
        let runner = RecordingGitRunner()
        let checker = GitUpdateChecker(cacheRoot: cache, runner: runner)
        let result = try await checker.checkLatest(
            strategy: .zipETag(URL(string: "https://example/x.zip")!))
        #expect(result == nil)
        #expect(runner.calls.isEmpty,
                "should not spawn git for a non-git strategy")
    }

    @Test
    func throwsWhenLogReturnsBlank() async throws {
        // SHA-less output means git found no commit touching the subdir
        // — e.g. a fresh manifest pointing at a path that doesn't exist
        // upstream yet. The checker should surface this rather than
        // returning a bogus ref.
        let cache = try makeTmpCache()
        defer { cleanup(cache) }
        let runner = RecordingGitRunner(outputs: ["", ""])  // log blank
        let checker = GitUpdateChecker(cacheRoot: cache, runner: runner)

        await #expect(throws: GitUpdateCheckerError.self) {
            _ = try await checker.checkLatest(strategy: .gitCommitForSubdir(
                repo: URL(string: "https://example/repo")!,
                subdir: "Bogus.spoon", ref: "main"))
        }
    }

    @Test
    func throwsWhenLogReturnsNonShaOutput() async throws {
        let cache = try makeTmpCache()
        defer { cleanup(cache) }
        let runner = RecordingGitRunner(outputs: ["", "not-a-sha"])
        let checker = GitUpdateChecker(cacheRoot: cache, runner: runner)

        await #expect(throws: GitUpdateCheckerError.self) {
            _ = try await checker.checkLatest(strategy: .gitCommitForSubdir(
                repo: URL(string: "https://example/repo")!,
                subdir: "X.spoon", ref: "main"))
        }
    }

    @Test
    func cacheKeyIsStableAndFilesystemSafe() {
        let checker = GitUpdateChecker(
            cacheRoot: URL(fileURLWithPath: "/tmp"),
            runner: RecordingGitRunner())
        let cases: [(String, String)] = [
            ("https://github.com/catokolas/HS_SpoonsContrib",
             "github.com-catokolas-HS_SpoonsContrib"),
            ("https://github.com/catokolas/HS_SpoonsContrib.git",
             "github.com-catokolas-HS_SpoonsContrib"),
            ("https://github.com/catokolas/HS_SpoonsContrib/",
             "github.com-catokolas-HS_SpoonsContrib"),
            ("http://example.com:8080/repo",
             "example.com-8080-repo"),
        ]
        for (input, expected) in cases {
            let key = checker.cacheKey(for: URL(string: input)!)
            #expect(key == expected, "\(input) → \(key) (want \(expected))")
            // No / or : that would break a single-segment path.
            #expect(!key.contains("/"))
            #expect(!key.contains(":"))
        }
    }

    // MARK: - Composite

    @Test
    func compositeRoutesToFirstChecker() async throws {
        let cache = try makeTmpCache()
        defer { cleanup(cache) }
        let sha = String(repeating: "b", count: 40)
        let runner = RecordingGitRunner(outputs: ["", sha])
        let checker = CompositeUpdateChecker([
            GitUpdateChecker(cacheRoot: cache, runner: runner)
        ])
        let result = try await checker.checkLatest(
            strategy: .gitCommitForSubdir(
                repo: URL(string: "https://example/repo")!,
                subdir: "X.spoon", ref: "main"))
        #expect(result == .gitCommit(sha))
    }

    @Test
    func compositeReturnsNilWhenNoChildHandles() async throws {
        let cache = try makeTmpCache()
        defer { cleanup(cache) }
        let runner = RecordingGitRunner()
        let checker = CompositeUpdateChecker([
            GitUpdateChecker(cacheRoot: cache, runner: runner)
        ])
        // ZipETag strategy — git checker says "not mine".
        let result = try await checker.checkLatest(
            strategy: .zipETag(URL(string: "https://example/x.zip")!))
        #expect(result == nil)
    }

    // MARK: - End-to-end with a real local git repo

    @Test
    func endToEndAgainstRealLocalRepo() async throws {
        // Build a tiny git repo with a Spoon-shaped subdir, make a
        // single commit, then ask the checker to identify that commit
        // as the latest one touching the subdir. Uses the real
        // SystemGitRunner so the full clone/fetch/log pipeline executes.
        let work = try makeTmpCache()
        defer { cleanup(work) }
        let upstream = work.appendingPathComponent("upstream")
        let spoonDir = upstream.appendingPathComponent("X.spoon")
        try FileManager.default.createDirectory(
            at: spoonDir, withIntermediateDirectories: true)
        try "-- v1".write(
            to: spoonDir.appendingPathComponent("init.lua"),
            atomically: true, encoding: .utf8)

        let git = try SystemGitRunner()
        _ = try await git.run(args: ["init", "-q", "-b", "main"],
                              cwd: upstream)
        _ = try await git.run(args: ["config", "user.email", "test@example"],
                              cwd: upstream)
        _ = try await git.run(args: ["config", "user.name", "Test"],
                              cwd: upstream)
        _ = try await git.run(args: ["add", "X.spoon"], cwd: upstream)
        _ = try await git.run(
            args: ["commit", "-q", "-m", "add X.spoon"], cwd: upstream)

        let expectedSha = try await git.run(
            args: ["rev-parse", "HEAD"], cwd: upstream)

        // file:// URL for the clone. The plain path also works on macOS.
        let cacheRoot = work.appendingPathComponent("cache")
        let checker = GitUpdateChecker(
            cacheRoot: cacheRoot, runner: git, cloneDepth: 5)

        let ref = try await checker.checkLatest(strategy: .gitCommitForSubdir(
            repo:   URL(fileURLWithPath: upstream.path),
            subdir: "X.spoon",
            ref:    "main"))

        #expect(ref == .gitCommit(expectedSha))

        // Second call: clone is cached, so the checker fetches instead.
        let ref2 = try await checker.checkLatest(strategy: .gitCommitForSubdir(
            repo:   URL(fileURLWithPath: upstream.path),
            subdir: "X.spoon",
            ref:    "main"))
        #expect(ref2 == .gitCommit(expectedSha))
    }

    // MARK: - Helpers

    private func makeTmpCache() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-checker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - UpdateCheckStrategy / CatalogSource

@Suite("UpdateCheckStrategy + CatalogSource defaults")
struct UpdateCheckStrategyTests {

    @Test
    func catokolasSourceUsesGitStrategy() {
        let source = CatokolasSource()
        let entry = SpoonCatalogEntry(
            id: "catokolas:FocusFollowsMouse",
            name: "FocusFollowsMouse",
            sourceID: "catokolas",
            metadata: SpoonMetadata(version: "0.1", description: nil,
                                    author: nil, homepage: nil, license: nil),
            lifecycle: Lifecycle(hasStart: true, hasStop: true,
                                 hasToggle: true, hasConfigure: true,
                                 eventDriven: false),
            config: [], hotkeys: [], provenance: .manifest)

        let strategy = source.updateCheckStrategy(for: entry)
        guard case .gitCommitForSubdir(let repo, let subdir, let ref) = strategy
        else {
            Issue.record("expected .gitCommitForSubdir, got \(strategy)")
            return
        }
        #expect(repo.absoluteString ==
                "https://github.com/catokolas/HS_SpoonsContrib")
        #expect(subdir == "FocusFollowsMouse.spoon")
        #expect(ref == "main")
    }

    @Test
    func updateAvailableComparesRefs() {
        #expect(!InstalledRef.updateAvailable(
            installed: nil, latest: .gitCommit("a")))
        #expect(!InstalledRef.updateAvailable(
            installed: .gitCommit("a"), latest: nil))
        #expect(!InstalledRef.updateAvailable(
            installed: .gitCommit("a"), latest: .gitCommit("a")))
        #expect(InstalledRef.updateAvailable(
            installed: .gitCommit("a"), latest: .gitCommit("b")))
    }
}
