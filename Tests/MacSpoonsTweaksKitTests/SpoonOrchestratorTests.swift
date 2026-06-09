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
        // configure → bindHotkeys (per orchestrator impl).
        #expect(runner.scripts.count == 2)
        #expect(runner.scripts[0]
                .contains(":configure({ delay = 0.05,"))
        #expect(runner.scripts[1]
                .contains(":bindHotkeys({ toggle = "))
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
        #expect(runner.scripts.count == 1)
        #expect(runner.scripts[0] ==
                "spoon.Caffeine.show_notifications = true")
    }

    @Test
    func applySkipsLiveCallsWhenNothingToPush() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        let runner = RecordingLuaRunner(returns: "")
        let orchestrator = makeOrchestrator(env: env, runner: runner)
        try await orchestrator.apply(
            entry: makeEntry(name: "X", sourceID: "catokolas",
                             hasConfigure: true, hasStart: true),
            values: [:], hotkeyOverrides: [:])
        // No configure / bindHotkeys script — nothing to push.
        #expect(runner.scripts.isEmpty)
        // State still persisted (Apply implies enable).
        let state = try env.store.load()
        #expect(state.spoons["X"]?.enabled == true)
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
