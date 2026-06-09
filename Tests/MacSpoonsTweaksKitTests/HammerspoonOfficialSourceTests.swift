import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("HammerspoonOfficialSource")
struct HammerspoonOfficialSourceTests {

    @Test
    func decodeProducesEntriesFromFixture() throws {
        let url = try #require(Bundle.module.url(
            forResource: "upstream-docs", withExtension: "json",
            subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let source = HammerspoonOfficialSource()
        let entries = try source.decode(data)

        // The fixture's NotAModule entry (type=Function) gets filtered;
        // the three actual Modules survive.
        #expect(entries.count == 3)
        #expect(entries.map(\.sourceID).allSatisfy {
            $0 == "hammerspoon-official"
        })
        #expect(entries.map(\.provenance).allSatisfy {
            $0 == .inferred
        })
        #expect(entries.contains { $0.name == "Caffeine" })
        #expect(entries.contains { $0.name == "TinyBrowser" })
    }

    @Test
    func updateCheckStrategyPointsAtTheCanonicalZipURL() {
        let source = HammerspoonOfficialSource()
        let entry = SpoonCatalogEntry(
            id: "hammerspoon-official:Caffeine",
            name: "Caffeine",
            sourceID: "hammerspoon-official",
            metadata: SpoonMetadata(version: "", description: nil,
                                    author: nil, homepage: nil, license: nil),
            lifecycle: Lifecycle(hasStart: true, hasStop: true,
                                 hasToggle: true, hasConfigure: false,
                                 eventDriven: false),
            config: [], hotkeys: [], provenance: .inferred)
        let strategy = source.updateCheckStrategy(for: entry)
        guard case .zipETag(let url) = strategy else {
            Issue.record("expected .zipETag, got \(strategy)")
            return
        }
        #expect(url.absoluteString ==
            "https://github.com/Hammerspoon/Spoons/raw/master/Spoons/Caffeine.spoon.zip")
    }

    @Test
    func sourceIDIsStable() {
        // sourceID is used as the SpoonInstall repo name. It must match
        // SpoonInstall's built-in "default" indirectly via the snippet
        // generator — and never drift away from what state.json
        // already stores against existing entries.
        #expect(HammerspoonOfficialSource().id == "hammerspoon-official")
    }
}
