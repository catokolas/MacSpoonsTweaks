import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("SpoonInstaller orchestration")
struct SpoonInstallerTests {

    // MARK: - Test runner

    /// LuaRunner that records every script and returns a configurable
    /// canned output per call. Lets us drive the installer past its
    /// success branch (`"ok"`) and failure branch (`"fail"`) without
    /// running the real `hs` CLI.
    final class ScriptedRunner: LuaRunner, @unchecked Sendable {
        let lock = NSLock()
        var scripts: [String] = []
        var outputs: [String]

        init(outputs: [String]) {
            self.outputs = outputs
        }

        func runLua(_ script: String, timeout: TimeInterval)
        async throws -> String {
            lock.lock(); defer { lock.unlock() }
            scripts.append(script)
            // Pop the next canned output; default to "" if we've run out
            // so a "best-effort" call (e.g. the unload during remove)
            // doesn't crash the test.
            if !outputs.isEmpty { return outputs.removeFirst() }
            return ""
        }
    }

    // MARK: - Tests

    @Test
    func installRunsTheBuiltScriptAndPersistsState() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        // SpoonInstall already in place — bootstrap is a no-op.
        try plantSpoonInstall(env)
        // After SpoonInstall reports "ok", create the destination dir to
        // simulate what the real Hammerspoon would do.
        let destDir = env.spoonsDir
            .appendingPathComponent("FocusFollowsMouse.spoon")
        try FileManager.default.createDirectory(
            at: destDir, withIntermediateDirectories: true)
        try Data("-- planted".utf8).write(
            to: destDir.appendingPathComponent("init.lua"))

        let runner = ScriptedRunner(outputs: ["ok"])
        let installer = SpoonInstaller(
            bootstrap: env.bootstrap, runner: runner, store: env.store)

        let entry = makeEntry(name: "FocusFollowsMouse", sourceID: "catokolas")
        let ref: InstalledRef = .gitCommit("abc1234")
        try await installer.install(
            entry: entry,
            from: .custom(
                id: "catokolas",
                url: "https://github.com/catokolas/HS_SpoonsContrib",
                branch: "main", desc: nil),
            installedRef: ref)

        // The runner saw the composed install script.
        #expect(runner.scripts.count == 1)
        #expect(runner.scripts[0].contains(
            ":installSpoonFromRepo(\"FocusFollowsMouse\", \"catokolas\")"))
        #expect(runner.scripts[0].contains("spoon.SpoonInstall.repos[\"catokolas\"]"))

        // State.json now has the new installedRef.
        let state = try env.store.load()
        #expect(state.spoons["FocusFollowsMouse"]?.installedRef == ref)
        #expect(state.spoons["FocusFollowsMouse"]?.sourceID == "catokolas")
    }

    @Test
    func installPreservesExistingConfigAndHotkeys() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        try plantSpoonInstall(env)
        try FileManager.default.createDirectory(
            at: env.spoonsDir.appendingPathComponent("FocusFollowsMouse.spoon"),
            withIntermediateDirectories: true)
        try Data().write(to: env.spoonsDir
            .appendingPathComponent("FocusFollowsMouse.spoon/init.lua"))

        // Pre-existing state.json with user-configured values — a typical
        // "update" scenario where the user has been running an older
        // version of the Spoon and we're advancing the installed commit.
        try env.store.update { state in
            state.spoons["FocusFollowsMouse"] = SpoonState(
                sourceID: "catokolas",
                enabled: true,
                installedRef: .gitCommit("oldsha"),
                config: ["delay": .number(0.05)],
                hotkeys: ["toggle": HotkeyBinding(mods: ["ctrl","alt"], key: "f")])
        }

        let runner = ScriptedRunner(outputs: ["ok"])
        let installer = SpoonInstaller(
            bootstrap: env.bootstrap, runner: runner, store: env.store)
        try await installer.install(
            entry: makeEntry(name: "FocusFollowsMouse", sourceID: "catokolas"),
            from: .custom(id: "catokolas",
                          url: "https://github.com/catokolas/HS_SpoonsContrib",
                          branch: "main", desc: nil),
            installedRef: .gitCommit("newsha"))

        let s = try env.store.load().spoons["FocusFollowsMouse"]
        #expect(s?.enabled == true,            "enabled preserved across update")
        #expect(s?.config["delay"] == .number(0.05), "config preserved")
        #expect(s?.hotkeys["toggle"]?.key == "f",    "hotkey preserved")
        #expect(s?.installedRef == .gitCommit("newsha"), "ref advances")
    }

    @Test
    func installThrowsWhenSpoonInstallReportsFail() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        try plantSpoonInstall(env)
        let runner = ScriptedRunner(outputs: ["fail"])
        let installer = SpoonInstaller(
            bootstrap: env.bootstrap, runner: runner, store: env.store)

        await #expect(throws: SpoonInstaller.InstallerError.self) {
            try await installer.install(
                entry: makeEntry(name: "X", sourceID: "default"),
                from: .default,
                installedRef: .zipETag(value: "etag", fetchedAt: Date()))
        }
        // State unchanged on failure.
        let state = try env.store.load()
        #expect(state.spoons["X"] == nil)
    }

    @Test
    func installAcceptsOKAfterLoadExtensionLogLines() async throws {
        // Real Hammerspoon stdout when the install script triggers a
        // first-time load of hs.http / hs.json: multi-line, with the
        // `ok` sentinel only on the final line.
        let env = try makeEnv()
        defer { cleanup(env) }
        try plantSpoonInstall(env)
        let destDir = env.spoonsDir.appendingPathComponent("X.spoon")
        try FileManager.default.createDirectory(
            at: destDir, withIntermediateDirectories: true)
        try Data("-- planted".utf8).write(
            to: destDir.appendingPathComponent("init.lua"))

        let runner = ScriptedRunner(outputs: [
            "-- Loading extension: http\n-- Loading extension: json\nok"
        ])
        let installer = SpoonInstaller(
            bootstrap: env.bootstrap, runner: runner, store: env.store)

        let fixedDate = Date(timeIntervalSince1970: 1_000_000)
        try await installer.install(
            entry: makeEntry(name: "X", sourceID: "default"),
            from: .default,
            installedRef: .zipETag(value: "etag", fetchedAt: fixedDate))
        let state = try env.store.load()
        #expect(state.spoons["X"]?.installedRef
                == .zipETag(value: "etag", fetchedAt: fixedDate))
    }

    @Test
    func installThrowsWhenDestinationStillMissing() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        try plantSpoonInstall(env)
        // No destination dir created — SpoonInstall says "ok" but the
        // file system disagrees. We must surface this rather than
        // pretending the install succeeded.
        let runner = ScriptedRunner(outputs: ["ok"])
        let installer = SpoonInstaller(
            bootstrap: env.bootstrap, runner: runner, store: env.store)

        await #expect(throws: SpoonInstaller.InstallerError.self) {
            try await installer.install(
                entry: makeEntry(name: "Missing", sourceID: "default"),
                from: .default,
                installedRef: .zipETag(value: "etag", fetchedAt: Date()))
        }
    }

    @Test
    func removeUnloadsAndDeletesDirAndClearsState() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        // Plant an installed Spoon both on disk and in state.json.
        let spoonDir = env.spoonsDir.appendingPathComponent("X.spoon")
        try FileManager.default.createDirectory(
            at: spoonDir, withIntermediateDirectories: true)
        try Data("-- installed".utf8).write(
            to: spoonDir.appendingPathComponent("init.lua"))
        try env.store.update { state in
            state.spoons["X"] = SpoonState(
                sourceID: "catokolas",
                enabled: true,
                installedRef: .gitCommit("abc"))
        }

        let runner = ScriptedRunner(outputs: [""])
        let installer = SpoonInstaller(
            bootstrap: env.bootstrap, runner: runner, store: env.store)
        try await installer.remove(name: "X")

        // Unload script went through the runner.
        #expect(runner.scripts.count == 1)
        #expect(runner.scripts[0].contains("spoon.X = nil"))

        // Directory and state are both gone.
        #expect(!FileManager.default.fileExists(atPath: spoonDir.path))
        let state = try env.store.load()
        #expect(state.spoons["X"] == nil)
    }

    @Test
    func removeIsIdempotentWhenSpoonAlreadyGone() async throws {
        // The user clicks Remove twice quickly, or the dir was deleted
        // out-of-band: the second call should NOT throw.
        let env = try makeEnv()
        defer { cleanup(env) }
        let runner = ScriptedRunner(outputs: [""])
        let installer = SpoonInstaller(
            bootstrap: env.bootstrap, runner: runner, store: env.store)
        try await installer.remove(name: "Absent")
        let state = try env.store.load()
        #expect(state.spoons["Absent"] == nil)
    }

    @Test
    func installRefusesWhenDestinationIsADevSymlink() async throws {
        // Dev workflow: ~/.hammerspoon/Spoons/<Name>.spoon is a symlink
        // into the local contrib checkout. SpoonInstall's `unzip -o`
        // can't extract over a symlinked target — pre-check refuses
        // with a clear, actionable error instead.
        let env = try makeEnv()
        defer { cleanup(env) }
        let realDir = env.root.appendingPathComponent("dev-checkout")
        try FileManager.default.createDirectory(
            at: realDir, withIntermediateDirectories: true)
        let link = env.spoonsDir.appendingPathComponent("DevSpoon.spoon")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: realDir)

        let runner = ScriptedRunner(outputs: ["ok"])
        let installer = SpoonInstaller(
            bootstrap: env.bootstrap, runner: runner, store: env.store)

        let entry = makeEntry(name: "DevSpoon", sourceID: "catokolas")
        await #expect(throws: SpoonInstaller.InstallerError.self) {
            try await installer.install(
                entry: entry, from: .default,
                installedRef: .gitCommit("abc"))
        }
        // Runner never invoked: the pre-check shortcircuits before
        // bootstrap or the Lua script.
        #expect(runner.scripts.isEmpty)
        // Symlink untouched.
        let stillLink = (try? link.resourceValues(
            forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        #expect(stillLink)
    }

    // MARK: - Helpers

    struct TestEnv {
        var root:      URL
        var spoonsDir: URL
        var statePath: URL
        var bootstrap: SpoonInstallBootstrap
        var store:     StateStore
    }

    private func makeEnv() throws -> TestEnv {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-\(UUID().uuidString)")
        let spoonsDir = root.appendingPathComponent("Spoons")
        let staging   = root.appendingPathComponent("staging")
        let statePath = root.appendingPathComponent("state.json")
        for d in [spoonsDir, staging] {
            try FileManager.default.createDirectory(
                at: d, withIntermediateDirectories: true)
        }
        // Bootstrap is configured but won't run download — tests plant
        // SpoonInstall.spoon directly.
        let bootstrap = SpoonInstallBootstrap(
            spoonsDir:  spoonsDir,
            stagingDir: staging,
            downloader: NeverDownloader())
        return TestEnv(root: root, spoonsDir: spoonsDir,
                       statePath: statePath,
                       bootstrap: bootstrap,
                       store: StateStore(path: statePath))
    }

    /// Errors if asked to download — tests should plant SpoonInstall
    /// directly so the bootstrap considers it already installed.
    final class NeverDownloader: ZipDownloader, @unchecked Sendable {
        func download(from url: URL) async throws -> URL {
            throw URLError(.cannotConnectToHost)
        }
    }

    private func cleanup(_ env: TestEnv) {
        try? FileManager.default.removeItem(at: env.root)
    }

    private func plantSpoonInstall(_ env: TestEnv) throws {
        let dir = env.bootstrap.destination
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try Data("-- planted SpoonInstall stub\n".utf8).write(
            to: dir.appendingPathComponent("init.lua"))
    }

    private func makeEntry(name: String, sourceID: String) -> SpoonCatalogEntry {
        return SpoonCatalogEntry(
            id: "\(sourceID):\(name)",
            name: name,
            sourceID: sourceID,
            metadata: SpoonMetadata(version: "0.1", description: nil,
                                    author: nil, homepage: nil, license: nil),
            lifecycle: Lifecycle(
                hasStart: true, hasStop: true, hasToggle: true,
                hasConfigure: true, eventDriven: false),
            config: [],
            hotkeys: [],
            provenance: .manifest)
    }
}
