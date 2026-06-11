import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("SpoonChangelogProvider")
struct SpoonChangelogProviderTests {

    private let repoURL = URL(string:
        "https://github.com/catokolas/HS_SpoonsContrib")!
    private let strategy = UpdateCheckStrategy.gitCommitForSubdir(
        repo:   URL(string: "https://github.com/catokolas/HS_SpoonsContrib")!,
        subdir: "FocusFollowsMouse.spoon",
        ref:    "main")

    // Manually-formatted "%H%x1f%s%x1f%an%x1f%aI%x1e" output: two
    // commits, the second one with a comma-laden subject to make sure
    // the field separator handles awkward content.
    private let twoCommitsRaw: String = {
        let us = "\u{1f}"
        let rs = "\u{1e}"
        return [
            "a".repeated(40) + us + "bump version" + us +
                "Cato" + us + "2026-06-09T12:00:00Z" + rs,
            "b".repeated(40) + us + "feat: add knownIssues, with comma" + us +
                "Cato" + us + "2026-06-08T08:30:00Z" + rs,
        ].joined(separator: "\n")
    }()

    @Test
    func parsesGitLogIntoSpoonCommits() async throws {
        let runner = RecordingGitRunner(outputs: [
            "",              // fetch (no output expected, succeeds)
            twoCommitsRaw,   // log
        ])
        let provider = GitSpoonChangelogProvider(runner: runner)
        let entry = makeEntry(name: "FocusFollowsMouse")

        let log = try await provider.changelog(
            for: entry, strategy: strategy,
            installed: .gitCommit(String(repeating: "c", count: 40)),
            latest:    .gitCommit(String(repeating: "a", count: 40)))

        #expect(log.precise == true)
        #expect(log.note == nil)
        #expect(log.commits.count == 2)
        #expect(log.commits[0].subject == "bump version")
        #expect(log.commits[1].subject == "feat: add knownIssues, with comma")
        #expect(log.commits[0].author == "Cato")
        // Compare URL is the GitHub compare view between installed
        // and latest SHAs.
        #expect(log.compareURL?.absoluteString.contains(
            "/compare/cccc") == true)
    }

    @Test
    func placeholderInstalledRefFallsBackToRecentCommits() async throws {
        let runner = RecordingGitRunner(outputs: [
            "",
            twoCommitsRaw,
        ])
        let provider = GitSpoonChangelogProvider(runner: runner)
        let entry = makeEntry(name: "FocusFollowsMouse")

        let log = try await provider.changelog(
            for: entry, strategy: strategy,
            // Either the "installed" placeholder or any non-hex SHA
            // should drop us into "recent commits" mode.
            installed: .gitCommit("installed"),
            latest:    .gitCommit(String(repeating: "a", count: 40)))

        #expect(log.precise == false)
        #expect(log.note != nil)
        // Compare URL falls back to /commits/<ref>.
        #expect(log.compareURL?.absoluteString.hasSuffix(
            "/commits/main") == true)
    }

    @Test
    func unsupportedStrategyThrowsForGitProvider() async {
        let runner = RecordingGitRunner()
        let provider = GitSpoonChangelogProvider(runner: runner)
        let entry = makeEntry(name: "AClock")
        let zipStrategy = UpdateCheckStrategy.zipETag(URL(string:
            "https://github.com/Hammerspoon/Spoons/raw/master/Spoons/AClock.spoon.zip")!)
        await #expect(throws: SpoonChangelogError.self) {
            _ = try await provider.changelog(
                for: entry, strategy: zipStrategy,
                installed: nil, latest: .gitCommit("a"))
        }
    }

    @Test
    func upstreamCommitsAPIDecodesAndMarksImprecise() throws {
        let json = """
        [
          {
            "sha": "abc1234567890abcdef1234567890abcdef12345",
            "commit": {
              "message": "AClock: tweak clock face\\n\\nBody we ignore.",
              "author": {
                "name": "Some Contributor",
                "date": "2026-06-09T15:00:00Z"
              }
            },
            "html_url": "https://github.com/Hammerspoon/Spoons/commit/abc1234"
          },
          {
            "sha": "def4567890abcdef1234567890abcdef12345abc",
            "commit": {
              "message": "AClock: refactor",
              "author": {
                "name": "Another",
                "date": "2026-06-05T07:00:00Z"
              }
            },
            "html_url": "https://github.com/Hammerspoon/Spoons/commit/def4567"
          }
        ]
        """
        let commits = try UpstreamCommitsAPIChangelogProvider.parse(
            json: Data(json.utf8),
            owner: "Hammerspoon", repo: "Spoons")
        #expect(commits.count == 2)
        // Multi-line messages are reduced to the first line only.
        #expect(commits[0].subject == "AClock: tweak clock face")
        #expect(commits[0].author  == "Some Contributor")
        #expect(commits[1].subject == "AClock: refactor")
    }

    // MARK: - Helpers

    private func makeEntry(name: String) -> SpoonCatalogEntry {
        return SpoonCatalogEntry(
            id: "catokolas:\(name)",
            name: name,
            sourceID: "catokolas",
            metadata: SpoonMetadata(
                version: "0.1", description: nil,
                author: nil, homepage: nil, license: nil),
            lifecycle: Lifecycle(
                hasStart: false, hasStop: false, hasToggle: false,
                hasConfigure: false, eventDriven: false),
            config: [], hotkeys: [],
            provenance: .manifest)
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        return String(repeating: self, count: count)
    }
}
