import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("OverrideApplier")
struct OverrideApplierTests {

    @Test
    func entryWithNoOverridePassesThroughUnchanged() {
        let entry = makeUpstreamEntry(
            name: "Caffeine",
            config: [.bool(BoolField(
                key: "show_notifications", label: nil, description: nil,
                advanced: nil, requires: nil, default: false))])
        let result = OverrideApplier.apply(
            entries: [entry], overrides: [:])
        #expect(result.count == 1)
        #expect(result[0].name == "Caffeine")
        #expect(result[0].provenance == .inferred)
        #expect(result[0].config.count == 1)
        #expect(result[0].config[0].key == "show_notifications")
    }

    @Test
    func entryWithOverrideGetsReplacedConfigAndProvenance() {
        let upstream = makeUpstreamEntry(
            name: "Caffeine",
            config: [.luaLiteral(LuaLiteralField(
                key: "x", label: nil, description: nil,
                advanced: nil, requires: nil, default: nil, luaHint: nil))])
        let override = makeManifest(
            name: "Caffeine",
            description: "Curated description",
            config: [.bool(BoolField(
                key: "show_notifications",
                label: "Show notifications",
                description: "When enabled, post a banner on state change.",
                advanced: nil, requires: nil, default: true))],
            hotkeys: [HotkeyAction(
                action: "toggle", label: "Toggle",
                default: HotkeyBinding(mods: ["ctrl","alt"], key: "k"))])

        let result = OverrideApplier.apply(
            entries: [upstream],
            overrides: ["Caffeine": override])

        let merged = result[0]
        #expect(merged.name == "Caffeine")
        #expect(merged.sourceID == "hammerspoon-official",
                "sourceID stays — override doesn't move the Spoon")
        #expect(merged.provenance == .override(of: "hammerspoon-official"))
        // Override's config replaces inferred config wholesale.
        #expect(merged.config.count == 1)
        if case .bool(let b) = merged.config[0] {
            #expect(b.label == "Show notifications")
            #expect(b.default == true)
        } else {
            Issue.record("expected bool field")
        }
        // Hotkeys also replaced (upstream didn't carry any).
        #expect(merged.hotkeys.count == 1)
        #expect(merged.hotkeys[0].action == "toggle")
        // Description from override fills the gap.
        #expect(merged.metadata.description == "Curated description")
    }

    @Test
    func metadataFallsThroughToUpstreamWhenOverrideDoesntSpecify() {
        // An override with nil description/author shouldn't WIPE the
        // upstream metadata — we want best-of-both.
        let upstream = makeUpstreamEntry(
            name: "X",
            metadata: SpoonMetadata(
                version: "", description: "Upstream desc",
                author: "Upstream Author",
                homepage: "https://upstream",
                license: "MIT"))
        let override = makeManifest(
            name: "X",
            description: nil, author: nil, homepage: nil, license: nil)
        let result = OverrideApplier.apply(
            entries: [upstream], overrides: ["X": override])
        let merged = result[0]
        #expect(merged.metadata.description == "Upstream desc")
        #expect(merged.metadata.author == "Upstream Author")
        #expect(merged.metadata.homepage == "https://upstream")
        #expect(merged.metadata.license == "MIT")
    }

    @Test
    func overrideLifecycleWinsOverInferred() {
        // Common case: docs.json says hasConfigure=false (no :configure
        // method documented), but the curator knows the upstream Spoon
        // takes config via direct assignment AND has a recently-added
        // :configure helper. The override's lifecycle must replace the
        // inferred one.
        let upstream = makeUpstreamEntry(
            name: "X",
            lifecycle: Lifecycle(
                hasStart: true, hasStop: true, hasToggle: true,
                hasConfigure: false, eventDriven: false))
        let override = makeManifest(
            name: "X",
            lifecycle: Lifecycle(
                hasStart: true, hasStop: true, hasToggle: true,
                hasConfigure: true, eventDriven: false))
        let result = OverrideApplier.apply(
            entries: [upstream], overrides: ["X": override])
        #expect(result[0].lifecycle.hasConfigure == true)
    }

    @Test
    func partialOverrideMapTouchesOnlyMatchedEntries() {
        let a = makeUpstreamEntry(name: "A")
        let b = makeUpstreamEntry(name: "B")
        let c = makeUpstreamEntry(name: "C")
        let override = makeManifest(name: "B")
        let result = OverrideApplier.apply(
            entries: [a, b, c],
            overrides: ["B": override])
        #expect(result[0].name == a.name)
        #expect(result[0].provenance == .inferred)
        #expect(result[1].name == b.name)
        #expect(result[1].provenance == .override(of: "hammerspoon-official"))
        #expect(result[2].name == c.name)
        #expect(result[2].provenance == .inferred)
    }

    // MARK: - Helpers

    private func makeUpstreamEntry(
        name: String,
        config: [ConfigField] = [],
        lifecycle: Lifecycle = Lifecycle(
            hasStart: true, hasStop: true, hasToggle: false,
            hasConfigure: false, eventDriven: false),
        metadata: SpoonMetadata = SpoonMetadata(
            version: "", description: nil,
            author: nil, homepage: nil, license: nil)
    ) -> SpoonCatalogEntry {
        return SpoonCatalogEntry(
            id: "hammerspoon-official:\(name)",
            name: name,
            sourceID: "hammerspoon-official",
            metadata: metadata,
            lifecycle: lifecycle,
            config: config,
            hotkeys: [],
            provenance: .inferred)
    }

    private func makeManifest(
        name: String,
        description: String? = nil,
        author: String? = nil,
        homepage: String? = nil,
        license: String? = nil,
        lifecycle: Lifecycle = Lifecycle(
            hasStart: true, hasStop: true, hasToggle: false,
            hasConfigure: true, eventDriven: false),
        config: [ConfigField] = [],
        hotkeys: [HotkeyAction] = []
    ) -> SpoonManifest {
        return SpoonManifest(
            schemaVersion: 1,
            name: name,
            version: "1.0",
            description: description,
            author: author,
            homepage: homepage,
            license: license,
            lifecycle: lifecycle,
            config: config,
            hotkeys: hotkeys)
    }
}

