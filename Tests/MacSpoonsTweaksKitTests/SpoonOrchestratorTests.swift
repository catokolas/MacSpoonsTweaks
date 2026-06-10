import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("SpoonOrchestrator")
struct SpoonOrchestratorTests {

    private let fixedDate = ISO8601DateFormatter().date(
        from: "2026-06-08T12:00:00Z")!

    // MARK: - apply: persist + snippet + live

    @Test
    func applyPersistsStateRegeneratesSnippetAndPushesLive() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        let runner = RecordingLuaRunner(returns: "")
        let orchestrator = makeOrchestrator(env: env, runner: runner)

        let entry = makeEntry(
            name: "FocusFollowsMouse",
            sourceID: "catokolas",
            hasConfigure: true, hasStart: true)
        try await orchestrator.apply(
            entry: entry,
            values: ["delay": .number(0.05),
                     "excludedApps": .stringList(["Notification Center"])],
            hotkeyOverrides: [
                "toggle": HotkeyBinding(mods: ["ctrl","cmd"], key: "f")
            ])

        // (1) State persisted.
        let state = try env.store.load()
        let ffm = try #require(state.spoons["FocusFollowsMouse"])
        #expect(ffm.sourceID == "catokolas")
        #expect(ffm.enabled == true)
        #expect(ffm.config["delay"] == .number(0.05))
        #expect(ffm.hotkeys["toggle"]?.key == "f")

        // (2) Snippet written.
        #expect(FileManager.default.fileExists(atPath: env.snippetPath.path))
        let snippet = try String(contentsOf: env.snippetPath, encoding: .utf8)
        #expect(snippet.contains(":andUse(\"FocusFollowsMouse\""))
        #expect(snippet.contains("fn = function(s) s:configure({"))
        #expect(snippet.contains("delay = 0.05"))
        #expect(snippet.contains("hotkeys = { toggle = "))

        // (3) Live apply ran in the right order.
        // loadSpoon → stop → configure → bindHotkeys → start.
        // loadSpoon makes first-time Apply work between Install and a
        // Hammerspoon reload; stop+start mirrors the snippet's
        // `start = true` so an event-driven Spoon actually takes
        // effect on Apply without needing a reload.
        #expect(runner.scripts.count == 5)
        #expect(runner.scripts[0]
                == "if not spoon.FocusFollowsMouse then "
                + "hs.loadSpoon(\"FocusFollowsMouse\") end")
        #expect(runner.scripts[1].contains(":stop()"))
        #expect(runner.scripts[2]
                .contains(":configure({ delay = 0.05,"))
        #expect(runner.scripts[3]
                .contains(":bindHotkeys({ toggle = "))
        #expect(runner.scripts[4].contains(":start()"))
    }

    @Test
    func applyMergesIntoExistingStatePreservingInstalledRef() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        let runner = RecordingLuaRunner(returns: "")
        let orchestrator = makeOrchestrator(env: env, runner: runner)

        // Plant existing state with an installedRef the installer
        // would have written. Apply should NOT clobber it.
        try env.store.update { state in
            state.spoons["FocusFollowsMouse"] = SpoonState(
                sourceID:     "catokolas",
                enabled:      true,
                installedRef: .gitCommit("oldsha"),
                config:       [:], hotkeys: [:])
        }

        try await orchestrator.apply(
            entry: makeEntry(name: "FocusFollowsMouse",
                             sourceID: "catokolas",
                             hasConfigure: true, hasStart: true),
            values: ["delay": .number(0.05)],
            hotkeyOverrides: [:])

        let ffm = try env.store.load().spoons["FocusFollowsMouse"]
        #expect(ffm?.installedRef == .gitCommit("oldsha"),
                "installedRef must survive Apply")
        #expect(ffm?.config["delay"] == .number(0.05))
    }

    @Test
    func applyForUpstreamSpoonUsesFlatConfigInLiveCall() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        let runner = RecordingLuaRunner(returns: "")
        let orchestrator = makeOrchestrator(env: env, runner: runner)

        let entry = makeEntry(
            name: "Caffeine",
            sourceID: "hammerspoon-official",
            hasConfigure: false,        // upstream: no :configure
            hasStart: true)
        try await orchestrator.apply(
            entry: entry,
            values: ["show_notifications": .bool(true)],
            hotkeyOverrides: [:])

        // The live call must use per-field assignment, not :configure.
        // loadSpoon runs first; stop+start bracket the assignment so an
        // event-driven Spoon picks up the new config without a reload.
        #expect(runner.scripts.count == 4)
        #expect(runner.scripts[0]
                == "if not spoon.Caffeine then "
                + "hs.loadSpoon(\"Caffeine\") end")
        #expect(runner.scripts[1].contains(":stop()"))
        #expect(runner.scripts[2] ==
                "spoon.Caffeine.show_notifications = true")
        #expect(runner.scripts[3].contains(":start()"))
    }

    @Test
    func applySkipsLiveCallsWhenNothingToPush() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        let runner = RecordingLuaRunner(returns: "")
        let orchestrator = makeOrchestrator(env: env, runner: runner)
        try await orchestrator.apply(
            entry: makeEntry(name: "X", sourceID: "catokolas",
                             hasConfigure: true, hasStart: false),
            values: [:], hotkeyOverrides: [:])
        // hasStart=false + nothing to push → no live calls at all.
        #expect(runner.scripts.isEmpty)
        // State still persisted (Apply implies enable).
        let state = try env.store.load()
        #expect(state.spoons["X"]?.enabled == true)
    }

    @Test
    func applyStartsEventDrivenSpoonEvenWithNoConfigOrHotkeys() async throws {
        // hasStart=true: empty Apply should still load+start the Spoon so
        // an event-driven Spoon (e.g. SpotifyPlayPause) actually takes
        // effect without needing a Hammerspoon reload.
        let env = try makeEnv()
        defer { cleanup(env) }
        let runner = RecordingLuaRunner(returns: "")
        let orchestrator = makeOrchestrator(env: env, runner: runner)
        try await orchestrator.apply(
            entry: makeEntry(name: "SpotifyPlayPause", sourceID: "catokolas",
                             hasConfigure: true, hasStart: true),
            values: [:], hotkeyOverrides: [:])
        #expect(runner.scripts.count == 3)
        #expect(runner.scripts[0]
                == "if not spoon.SpotifyPlayPause then "
                + "hs.loadSpoon(\"SpotifyPlayPause\") end")
        #expect(runner.scripts[1].contains(":stop()"))
        #expect(runner.scripts[2].contains(":start()"))
    }

    @Test
    func applyRecordsLiveErrorButStillPersists() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        let runner = FailingLuaRunner()      // throws on every runLua
        let orchestrator = makeOrchestrator(env: env, runner: runner)

        let result = try await orchestrator.apply(
            entry: makeEntry(name: "X", sourceID: "catokolas",
                             hasConfigure: true, hasStart: true),
            values: ["delay": .number(0.1)],
            hotkeyOverrides: [:])

        // Live apply failed but persistence/snippet succeeded.
        #expect(result.liveAppliedOK == false)
        #expect(result.liveApplyError != nil)
        let state = try env.store.load()
        #expect(state.spoons["X"]?.config["delay"] == .number(0.1))
        #expect(FileManager.default.fileExists(atPath: env.snippetPath.path))
    }

    @Test
    func applyAggregatesMultipleLiveErrors() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        let runner = FailingLuaRunner()
        let orchestrator = makeOrchestrator(env: env, runner: runner)

        let result = try await orchestrator.apply(
            entry: makeEntry(name: "X", sourceID: "catokolas",
                             hasConfigure: true, hasStart: true),
            values: ["delay": .number(0.1)],
            hotkeyOverrides: [
                "toggle": HotkeyBinding(mods: ["ctrl"], key: "f")
            ])
        #expect(result.liveAppliedOK == false)
        let msg = result.liveApplyError ?? ""
        #expect(msg.contains("|"),
                "expected both errors joined, got: \(msg)")
    }

    // MARK: - pause / resume

    @Test
    func setPausedTrueWritesStateRegeneratesSnippetAndStopsSpoon()
    async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        // Seed an enabled, configured Spoon as if the user had already
        // applied — pause toggles the existing state.
        try env.store.update { state in
            state.spoons["FocusFollowsMouse"] = SpoonState(
                sourceID: "catokolas",
                enabled:  true,
                installedRef: .gitCommit("abc"),
                config:  ["delay": .number(0.05)])
        }
        let runner = RecordingLuaRunner(returns: "")
        let orchestrator = makeOrchestrator(env: env, runner: runner)
        let entry = makeEntry(name: "FocusFollowsMouse",
                              sourceID: "catokolas",
                              hasConfigure: true, hasStart: true)

        let result = try await orchestrator.setPaused(
            entry: entry, paused: true)

        #expect(result.liveAppliedOK == true)
        // State.paused flipped.
        let s = try env.store.load().spoons["FocusFollowsMouse"]
        #expect(s?.paused == true)
        #expect(s?.enabled == true)            // enabled untouched
        // Snippet still has the block but no `start = true`.
        let snippet = try String(contentsOf: env.snippetPath, encoding: .utf8)
        #expect(snippet.contains(":andUse(\"FocusFollowsMouse\""))
        #expect(snippet.contains(":configure({ delay = 0.05"))
        #expect(!snippet.contains("start = true"))
        // Live: only :stop() was called.
        #expect(runner.scripts.count == 1)
        #expect(runner.scripts[0].contains(":stop()"))
    }

    @Test
    func setPausedFalseRestartsSpoon() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        // Start from a paused state.
        try env.store.update { state in
            state.spoons["FocusFollowsMouse"] = SpoonState(
                sourceID: "catokolas",
                enabled:  true,
                paused:   true,
                installedRef: .gitCommit("abc"))
        }
        let runner = RecordingLuaRunner(returns: "")
        let orchestrator = makeOrchestrator(env: env, runner: runner)
        let entry = makeEntry(name: "FocusFollowsMouse",
                              sourceID: "catokolas",
                              hasConfigure: true, hasStart: true)

        let result = try await orchestrator.setPaused(
            entry: entry, paused: false)

        #expect(result.liveAppliedOK == true)
        let s = try env.store.load().spoons["FocusFollowsMouse"]
        #expect(s?.paused == false)
        let snippet = try String(contentsOf: env.snippetPath, encoding: .utf8)
        #expect(snippet.contains("start = true"))
        // Live: idempotent loadSpoon, then :start().
        #expect(runner.scripts.count == 2)
        #expect(runner.scripts[0]
                == "if not spoon.FocusFollowsMouse then "
                + "hs.loadSpoon(\"FocusFollowsMouse\") end")
        #expect(runner.scripts[1].contains(":start()"))
    }

    @Test
    func pausedFlagSurvivesStoreRoundTrip() throws {
        // Belt-and-braces: write paused=true, reload, verify.
        let env = try makeEnv()
        defer { cleanup(env) }
        try env.store.update { state in
            state.spoons["X"] = SpoonState(
                sourceID: "catokolas",
                enabled:  true,
                paused:   true)
        }
        let reloaded = try env.store.load()
        #expect(reloaded.spoons["X"]?.paused == true)
    }

    // MARK: - seedState

    @Test
    func seedStateReturnsEmptyForUnknownSpoon() {
        let env = try! makeEnv()
        defer { cleanup(env) }
        let orchestrator = makeOrchestrator(env: env,
                                            runner: RecordingLuaRunner())
        let (config, hotkeys) = orchestrator.seedState(for: "Nobody")
        #expect(config.isEmpty)
        #expect(hotkeys.isEmpty)
    }

    @Test
    func seedStateReturnsExistingOverridesForKnownSpoon() throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        try env.store.update { state in
            state.spoons["FocusFollowsMouse"] = SpoonState(
                sourceID:    "catokolas",
                enabled:     true,
                installedRef: .gitCommit("abc"),
                config:      ["delay": .number(0.05)],
                hotkeys:     [
                    "toggle": HotkeyBinding(mods: ["ctrl"], key: "f")
                ])
        }
        let orchestrator = makeOrchestrator(env: env,
                                            runner: RecordingLuaRunner())
        let (config, hotkeys) =
            orchestrator.seedState(for: "FocusFollowsMouse")
        #expect(config["delay"] == .number(0.05))
        #expect(hotkeys["toggle"]?.key == "f")
    }

    // MARK: - Test environment

    struct Env {
        var root:        URL
        var store:       StateStore
        var snippetPath: URL
    }

    private func makeEnv() throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return Env(
            root: root,
            store: StateStore(path: root.appendingPathComponent("state.json")),
            snippetPath: root.appendingPathComponent("mac_spoons_tweaks.lua"))
    }

    private func cleanup(_ env: Env) {
        try? FileManager.default.removeItem(at: env.root)
    }

    private func makeOrchestrator(
        env: Env,
        runner: any LuaRunner
    ) -> SpoonOrchestrator {
        return SpoonOrchestrator(
            store:       env.store,
            runner:      runner,
            snippetPath: env.snippetPath,
            catalogProvider: { Self.catalogForTests() },
            reposProvider:   { ["catokolas": Self.catokolasRepo] },
            clock:           { ISO8601DateFormatter().date(
                from: "2026-06-08T12:00:00Z")! })
    }

    static let catokolasRepo: RepoRef = .custom(
        id: "catokolas",
        url: "https://github.com/catokolas/HS_SpoonsContrib",
        branch: "main",
        desc: "Cato's Spoons")

    static func catalogForTests() -> [String: SpoonCatalogEntry] {
        return [
            "FocusFollowsMouse": makeEntry(
                name: "FocusFollowsMouse",
                sourceID: "catokolas",
                hasConfigure: true,
                hasStart: true),
            "Caffeine": makeEntry(
                name: "Caffeine",
                sourceID: "hammerspoon-official",
                hasConfigure: false,
                hasStart: true),
            "X": makeEntry(
                name: "X",
                sourceID: "catokolas",
                hasConfigure: true,
                hasStart: true),
        ]
    }

    static func makeEntry(
        name: String,
        sourceID: String,
        hasConfigure: Bool,
        hasStart: Bool
    ) -> SpoonCatalogEntry {
        return SpoonCatalogEntry(
            id: "\(sourceID):\(name)",
            name: name,
            sourceID: sourceID,
            metadata: SpoonMetadata(
                version: "0.1", description: nil,
                author: nil, homepage: nil, license: nil),
            lifecycle: Lifecycle(
                hasStart: hasStart, hasStop: true, hasToggle: false,
                hasConfigure: hasConfigure, eventDriven: false),
            config:  [], hotkeys: [],
            provenance: .manifest)
    }

    private func makeEntry(
        name: String, sourceID: String,
        hasConfigure: Bool, hasStart: Bool
    ) -> SpoonCatalogEntry {
        return Self.makeEntry(
            name: name, sourceID: sourceID,
            hasConfigure: hasConfigure, hasStart: hasStart)
    }
}

// MARK: - Failing runner

final class FailingLuaRunner: LuaRunner, @unchecked Sendable {
    enum SyntheticError: Error { case bridgeNotConnected }
    func runLua(_ script: String, timeout: TimeInterval)
    async throws -> String {
        throw HammerspoonBridgeError.luaError(stderr: "(synthetic)")
    }
}
