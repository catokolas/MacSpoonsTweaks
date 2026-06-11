import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("UserCatalogSource")
struct UserCatalogSourceTests {

    @Test
    func idIsNamespacedToUser() {
        let cfg = CustomCatalogConfig(
            owner: "alice", repo: "spoons-curated")
        let src = UserCatalogSource(config: cfg)
        #expect(src.id == "user:alice/spoons-curated")
    }

    @Test
    func repoRefMatchesGitHubRepoAndBranch() {
        let cfg = CustomCatalogConfig(
            owner: "alice", repo: "spoons-curated",
            branch: "next", description: "Alice's picks")
        let src = UserCatalogSource(config: cfg)
        guard case .custom(let id, let url, let branch, let desc) = src.repoRef
        else { Issue.record("expected .custom"); return }
        #expect(id     == "user:alice/spoons-curated")
        #expect(url    == "https://github.com/alice/spoons-curated")
        #expect(branch == "next")
        #expect(desc   == "Alice's picks")
    }

    @Test
    func decodeProducesEntriesTaggedWithUserSourceID() throws {
        let json = """
        {
          "schemaVersion": 1,
          "repo": "alice/spoons-curated",
          "spoons": [
            {
              "schemaVersion": 1,
              "name": "TinySpoon",
              "version": "0.1",
              "lifecycle": {
                "hasStart": false, "hasStop": false, "hasToggle": false,
                "hasConfigure": false, "eventDriven": false
              },
              "config": [],
              "hotkeys": []
            }
          ],
          "overrides": {}
        }
        """
        let cfg = CustomCatalogConfig(
            owner: "alice", repo: "spoons-curated")
        let src = UserCatalogSource(config: cfg)
        let entries = try src.decode(Data(json.utf8))
        #expect(entries.count == 1)
        #expect(entries[0].name == "TinySpoon")
        #expect(entries[0].sourceID == "user:alice/spoons-curated")
        #expect(entries[0].id == "user:alice/spoons-curated:TinySpoon")
    }

    @Test
    func updateCheckStrategyResolvesToGitForUserCatalog() {
        let cfg = CustomCatalogConfig(
            owner: "alice", repo: "spoons-curated", branch: "next")
        let src = UserCatalogSource(config: cfg)
        // Build a sample entry with the correct sourceID so the
        // strategy can construct the right subdir.
        let entry = SpoonCatalogEntry(
            id: "user:alice/spoons-curated:TinySpoon",
            name: "TinySpoon",
            sourceID: "user:alice/spoons-curated",
            metadata: SpoonMetadata(
                version: "0.1", description: nil,
                author: nil, homepage: nil, license: nil),
            lifecycle: Lifecycle(
                hasStart: false, hasStop: false, hasToggle: false,
                hasConfigure: false, eventDriven: false),
            config: [], hotkeys: [],
            provenance: .manifest)

        guard case .gitCommitForSubdir(let repo, let subdir, let ref) =
            src.updateCheckStrategy(for: entry)
        else { Issue.record("expected .gitCommitForSubdir"); return }
        #expect(repo.absoluteString ==
                "https://github.com/alice/spoons-curated")
        #expect(subdir == "TinySpoon.spoon")
        #expect(ref    == "next")
    }
}
