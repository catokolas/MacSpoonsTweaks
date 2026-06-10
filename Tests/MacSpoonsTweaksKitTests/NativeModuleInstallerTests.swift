import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("NativeModuleInstaller")
struct NativeModuleInstallerTests {

    @Test
    func installFreshUnzipsIntoHammerspoonDir() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        let module = OptionalModule(
            name: "hs._ckol.foo",
            repo: "catokolas/HS_ModulesContrib-foo",
            installSubdir: "hs/_ckol/foo",
            assetPattern: "foo-*-macos-universal.zip",
            description: "test")
        let zip = try makeFixtureZip(
            withSubdir: "hs/_ckol/foo",
            fileName: "init.lua",
            contents: "-- planted")
        let release = GitHubRelease(
            tagName: "v0.1",
            assets: [GitHubReleaseAsset(
                name: "foo-0.1-macos-universal.zip",
                browserDownloadURL: URL(string: "https://example.invalid/")!)])
        let installer = makeInstaller(env: env, release: release, fixtureZip: zip)

        let result = try await installer.install(module: module)

        #expect(result.tagName == "v0.1")
        let destFile = env.hsRoot
            .appendingPathComponent("hs/_ckol/foo/init.lua")
        let bytes = try Data(contentsOf: destFile)
        #expect(String(data: bytes, encoding: .utf8) == "-- planted")
        // State.json now records the installed version.
        let state = try env.store.load()
        #expect(state.nativeModules["hs._ckol.foo"]?
                .installedVersion == "v0.1")
        // isInstalled reflects the FS check.
        #expect(installer.isInstalled(module))
    }

    @Test
    func installRejectsReleaseWithNoMatchingAsset() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        let module = OptionalModule(
            name: "hs._ckol.foo",
            repo: "catokolas/HS_ModulesContrib-foo",
            installSubdir: "hs/_ckol/foo",
            assetPattern: "foo-*-macos-universal.zip",
            description: "test")
        // Release has assets but none match the pattern.
        let release = GitHubRelease(
            tagName: "v0.2",
            assets: [GitHubReleaseAsset(
                name: "foo-0.2-linux-x86_64.zip",
                browserDownloadURL: URL(string: "https://example.invalid/")!)])
        let installer = makeInstaller(
            env: env, release: release,
            fixtureZip: try makeFixtureZip(
                withSubdir: "hs/_ckol/foo",
                fileName: "init.lua", contents: ""))

        await #expect(throws: NativeModuleInstaller.InstallerError.self) {
            _ = try await installer.install(module: module)
        }
    }

    @Test
    func removeDeletesInstalledSubtreeAndClearsState() async throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        let module = OptionalModule(
            name: "hs._ckol.foo",
            repo: "catokolas/HS_ModulesContrib-foo",
            installSubdir: "hs/_ckol/foo",
            assetPattern: "foo-*.zip",
            description: "test")
        let dir = env.hsRoot.appendingPathComponent("hs/_ckol/foo")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(
            to: dir.appendingPathComponent("internal.so"))
        try env.store.update { state in
            state.nativeModules["hs._ckol.foo"] = NativeModuleState(
                installedVersion: "v0.1", installedAt: Date())
        }
        let installer = makeInstaller(env: env, release: nil, fixtureZip: nil)

        try installer.remove(module: module)

        #expect(!FileManager.default.fileExists(atPath: dir.path))
        let state = try env.store.load()
        #expect(state.nativeModules["hs._ckol.foo"] == nil)
    }

    @Test
    func isInstalledReflectsFilesystemNotState() throws {
        let env = try makeEnv()
        defer { cleanup(env) }
        let module = OptionalModule(
            name: "hs._ckol.foo",
            repo: "catokolas/HS_ModulesContrib-foo",
            installSubdir: "hs/_ckol/foo",
            assetPattern: "foo-*.zip",
            description: "test")
        let installer = makeInstaller(env: env, release: nil, fixtureZip: nil)
        #expect(!installer.isInstalled(module))
        try FileManager.default.createDirectory(
            at: env.hsRoot.appendingPathComponent("hs/_ckol/foo"),
            withIntermediateDirectories: true)
        #expect(installer.isInstalled(module))
    }

    // MARK: - Helpers

    struct TestEnv {
        var root:   URL
        var hsRoot: URL          // pretend ~/.hammerspoon
        var store:  StateStore
    }

    private func makeEnv() throws -> TestEnv {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("modinst-\(UUID().uuidString)")
        let hsRoot = root.appendingPathComponent("hammerspoon")
        let statePath = root.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(
            at: hsRoot, withIntermediateDirectories: true)
        return TestEnv(root: root, hsRoot: hsRoot,
                       store: StateStore(path: statePath))
    }

    private func cleanup(_ env: TestEnv) {
        try? FileManager.default.removeItem(at: env.root)
    }

    private func makeInstaller(
        env: TestEnv,
        release: GitHubRelease?,
        fixtureZip: URL?
    ) -> NativeModuleInstaller {
        let releases = RecordingGitHubReleasesClient()
        if let release = release {
            releases.enqueue(release,
                             for: "catokolas/HS_ModulesContrib-foo")
        }
        return NativeModuleInstaller(
            hammerspoonRoot: env.hsRoot,
            stagingDir: env.root.appendingPathComponent("stage"),
            releases: releases,
            downloader: FixedZipDownloader(zip: fixtureZip),
            store: env.store)
    }

    /// Build a real zip containing `<subdir>/<fileName>` with the
    /// given text contents. We shell out to `/usr/bin/zip` so the
    /// installer's `unzip` extracts a real archive.
    private func makeFixtureZip(
        withSubdir subdir: String,
        fileName: String,
        contents: String
    ) throws -> URL {
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: stage, withIntermediateDirectories: true)
        let inner = stage.appendingPathComponent(subdir)
        try FileManager.default.createDirectory(
            at: inner, withIntermediateDirectories: true)
        try Data(contents.utf8).write(
            to: inner.appendingPathComponent(fileName))

        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixzip-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", zipURL.path, "."]
        process.currentDirectoryURL = stage
        try process.run()
        process.waitUntilExit()
        return zipURL
    }

    /// Hands out a pre-built fixture zip in place of a network download.
    final class FixedZipDownloader: ZipDownloader, @unchecked Sendable {
        let zip: URL?
        init(zip: URL?) { self.zip = zip }
        func download(from url: URL) async throws -> URL {
            guard let zip = zip else {
                throw URLError(.cannotConnectToHost)
            }
            return zip
        }
    }
}
