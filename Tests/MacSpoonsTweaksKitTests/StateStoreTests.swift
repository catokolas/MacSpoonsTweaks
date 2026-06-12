import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("StateStore")
struct StateStoreTests {

    @Test
    func missingFileLoadsAsDefaultEmptyState() throws {
        let store = StateStore(path: tmpPath())
        let s = try store.load()
        #expect(s.schemaVersion == 1)
        #expect(s.spoons.isEmpty)
        #expect(s.catalogETags.isEmpty)
    }

    @Test
    func roundTripPreservesSpoonEntry() throws {
        let path = tmpPath()
        let store = StateStore(path: path)
        var state = AppState()
        state.spoons["FocusFollowsMouse"] = SpoonState(
            sourceID: "catokolas",
            enabled: true,
            installedRef: .gitCommit("abc1234"),
            config: ["delay": .number(0.05),
                     "excludedApps": .stringList(["Notification Center"])],
            hotkeys: ["toggle": HotkeyBinding(mods: ["ctrl", "cmd"], key: "f")])
        try store.save(state)

        let reloaded = try store.load()
        #expect(reloaded == state)
    }

    @Test
    func roundTripPreservesEnumInstalledRefVariants() throws {
        let path = tmpPath()
        let store = StateStore(path: path)
        var state = AppState()
        let now = Date()
        state.spoons["Ours"] = SpoonState(
            sourceID: "catokolas",
            installedRef: .gitCommit("deadbeef"))
        state.spoons["Caffeine"] = SpoonState(
            sourceID: "hammerspoon-official",
            installedRef: .zipETag(value: "W/\"abc\"", fetchedAt: now))
        try store.save(state)

        let reloaded = try store.load()
        #expect(reloaded.spoons["Ours"]?.installedRef == .gitCommit("deadbeef"))
        // Date equality survives the ISO8601 round-trip if we compare via
        // wall-clock second precision (the encoder/decoder use ISO8601).
        guard case .zipETag(let v, let d)? =
                reloaded.spoons["Caffeine"]?.installedRef else {
            Issue.record("expected .zipETag for Caffeine")
            return
        }
        #expect(v == "W/\"abc\"")
        // Tolerate ≤1s drift from the ISO8601 serialization granularity.
        #expect(abs(d.timeIntervalSince(now)) < 1.0)
    }

    @Test
    func unknownInstalledRefKindThrows() {
        let path = tmpPath()
        // Hand-write a payload with a bogus kind to ensure we don't
        // silently accept it (would let stale code paths run against
        // garbage data).
        let bad = """
          {
            "schemaVersion": 1,
            "catalogETags": {},
            "lastCatalogFetch": {},
            "spoons": {
              "X": {
                "sourceID": "catokolas",
                "enabled": false,
                "config": {},
                "hotkeys": {},
                "installedRef": { "kind": "mystery", "value": "?" }
              }
            }
          }
          """
        try? bad.write(to: path, atomically: true, encoding: .utf8)
        let store = StateStore(path: path)
        #expect(throws: (any Error).self) { _ = try store.load() }
    }

    @Test
    func atomicWriteCreatesParentDirectory() throws {
        // First write into a non-existent dir tree — createDirectory
        // should make it.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSpoonsTweaksTests-" + UUID().uuidString)
            .appendingPathComponent("nested")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let path = dir.appendingPathComponent("state.json")
        let store = StateStore(path: path)
        try store.save(AppState(spoons: [
            "X": SpoonState(sourceID: "catokolas", enabled: true)
        ]))
        #expect(FileManager.default.fileExists(atPath: path.path))
        let reloaded = try store.load()
        #expect(reloaded.spoons["X"]?.enabled == true)
    }

    @Test
    func updateAppliesMutationAndPersists() throws {
        let store = StateStore(path: tmpPath())
        let result = try store.update { state in
            state.spoons["X"] = SpoonState(sourceID: "catokolas", enabled: true)
            state.catalogETags["catokolas"] = "\"etag1\""
        }
        #expect(result.spoons["X"]?.enabled == true)
        let reloaded = try store.load()
        #expect(reloaded.spoons["X"]?.enabled == true)
        #expect(reloaded.catalogETags["catokolas"] == "\"etag1\"")
    }

    @Test
    func sortedKeysOutputForStableDiffs() throws {
        // The encoder uses .sortedKeys so file diffs across runs are
        // stable — useful when the user inspects state.json themselves.
        let path = tmpPath()
        let store = StateStore(path: path)
        try store.save(AppState(spoons: [
            "Zebra":  SpoonState(sourceID: "catokolas"),
            "Alpha":  SpoonState(sourceID: "catokolas"),
        ]))
        let text = try String(contentsOf: path, encoding: .utf8)
        let alphaIdx = text.range(of: "\"Alpha\"")!.lowerBound
        let zebraIdx = text.range(of: "\"Zebra\"")!.lowerBound
        #expect(alphaIdx < zebraIdx)
    }

    @Test
    func loadingPreviousStateDefaultsPausedToFalse() throws {
        // State files written before the `paused` field existed must
        // still decode cleanly — paused defaults to false.
        let path = tmpPath()
        let json = """
        {
          "schemaVersion": 1,
          "lastCatalogFetch": {},
          "catalogETags": {},
          "spoons": {
            "Old": {
              "sourceID": "catokolas",
              "enabled": true,
              "config": {},
              "hotkeys": {}
            }
          }
        }
        """
        try json.write(to: path, atomically: true, encoding: .utf8)
        let store = StateStore(path: path)
        let state = try store.load()
        #expect(state.spoons["Old"]?.enabled == true)
        #expect(state.spoons["Old"]?.paused == false)
    }

    @Test
    func customCatalogsRoundTripAndDefaultToEmpty() throws {
        // Legacy state.json has no customCatalogs key → empty array;
        // round-trip preserves the entries we wrote.
        let pathOld = tmpPath()
        try """
        {
          "schemaVersion": 1,
          "lastCatalogFetch": {},
          "catalogETags": {},
          "spoons": {}
        }
        """.write(to: pathOld, atomically: true, encoding: .utf8)
        let oldState = try StateStore(path: pathOld).load()
        #expect(oldState.customCatalogs.isEmpty)

        let pathNew = tmpPath()
        let store   = StateStore(path: pathNew)
        try store.save(AppState(customCatalogs: [
            CustomCatalogConfig(
                owner: "alice", repo: "spoons-curated",
                branch: "main", description: "Alice's picks",
                enabled: true),
            CustomCatalogConfig(
                owner: "bob",   repo: "more-spoons",
                branch: "next", description: nil,
                enabled: false),
        ]))
        let reloaded = try store.load()
        #expect(reloaded.customCatalogs.count == 2)
        #expect(reloaded.customCatalogs[0].id == "alice/spoons-curated")
        #expect(reloaded.customCatalogs[0].description == "Alice's picks")
        #expect(reloaded.customCatalogs[1].enabled == false)
        #expect(reloaded.customCatalogs[1].branch == "next")
    }

    @Test
    func nativeModulesRoundTripsAndDefaultsToEmpty() throws {
        // Legacy state.json without nativeModules → empty map; new
        // state with entries → round-trips back as written.
        let pathOld = tmpPath()
        try """
        {
          "schemaVersion": 1,
          "lastCatalogFetch": {},
          "catalogETags": {},
          "spoons": {}
        }
        """.write(to: pathOld, atomically: true, encoding: .utf8)
        let oldState = try StateStore(path: pathOld).load()
        #expect(oldState.nativeModules.isEmpty)

        let pathNew = tmpPath()
        let store = StateStore(path: pathNew)
        let fixed = Date(timeIntervalSince1970: 1_000_000)
        try store.save(AppState(nativeModules: [
            "hs._ckol.multitouch":
                NativeModuleState(installedVersion: "v0.1", installedAt: fixed)
        ]))
        let reloaded = try store.load()
        #expect(reloaded.nativeModules["hs._ckol.multitouch"]?
                .installedVersion == "v0.1")
        #expect(reloaded.nativeModules["hs._ckol.multitouch"]?
                .installedAt == fixed)
    }

    @Test
    func legacyStateMissingFontSizeDefaultsToXLarge() throws {
        // state.json from before the font-size feature has no key.
        // Decoder must default to .xLarge (preserves pre-feature look).
        let path = tmpPath()
        try """
        {
          "schemaVersion": 1,
          "lastCatalogFetch": {},
          "catalogETags": {},
          "spoons": {}
        }
        """.write(to: path, atomically: true, encoding: .utf8)
        let state = try StateStore(path: path).load()
        #expect(state.fontSize == .xLarge)
    }

    @Test
    func fontSizeRoundTrips() throws {
        let path = tmpPath()
        let store = StateStore(path: path)
        try store.save(AppState(fontSize: .accessibility1))
        #expect(try store.load().fontSize == .accessibility1)
        // Round-trip each value to catch raw-string typos.
        for preset in FontSizePreset.allCases {
            try store.save(AppState(fontSize: preset))
            #expect(try store.load().fontSize == preset)
        }
    }

    // MARK: helpers

    private func tmpPath() -> URL {
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("state-\(UUID().uuidString).json")
    }
}
