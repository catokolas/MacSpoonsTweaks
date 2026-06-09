import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("SpoonInstallBootstrap")
struct SpoonInstallBootstrapTests {

    // MARK: - Test downloaders

    /// Returns a pre-built zip file by simply copying it. Throws if
    /// asked to download more than once or after `failOnDownload` is set.
    final class FixtureDownloader: ZipDownloader, @unchecked Sendable {
        let zipURL: URL
        var callCount = 0
        var failOnDownload = false

        init(zipURL: URL) { self.zipURL = zipURL }

        func download(from url: URL) async throws -> URL {
            callCount += 1
            if failOnDownload {
                throw URLError(.networkConnectionLost)
            }
            return zipURL
        }
    }

    /// Errors if called — proves that the bootstrap didn't touch the
    /// network at all (for the idempotent-skip case).
    final class NeverDownloader: ZipDownloader, @unchecked Sendable {
        func download(from url: URL) async throws -> URL {
            throw URLError(.cannotConnectToHost)
        }
    }

    // MARK: - Tests

    @Test
    func alreadyInstalledSkipsDownload() async throws {
        let dirs = try makeDirs()
        defer { cleanup(dirs) }
        // Plant an existing SpoonInstall.spoon/init.lua.
        let dest = dirs.spoonsDir
            .appendingPathComponent("SpoonInstall.spoon")
        try FileManager.default.createDirectory(
            at: dest, withIntermediateDirectories: true)
        try Data("--existing".utf8).write(
            to: dest.appendingPathComponent("init.lua"))

        let bootstrap = SpoonInstallBootstrap(
            spoonsDir:   dirs.spoonsDir,
            stagingDir:  dirs.stagingDir,
            downloadURL: URL(string: "https://example.invalid/")!,
            downloader:  NeverDownloader())

        #expect(bootstrap.isInstalled)
        try await bootstrap.ensureInstalled()
        // Existing init.lua is untouched (still has "--existing" marker).
        let kept = try String(
            contentsOf: dest.appendingPathComponent("init.lua"),
            encoding: .utf8)
        #expect(kept == "--existing")
    }

    @Test
    func freshInstallUnzipsAndPlaces() async throws {
        let dirs = try makeDirs()
        defer { cleanup(dirs) }
        let fixture = try makeFixtureZip(in: dirs.workDir)
        let bootstrap = SpoonInstallBootstrap(
            spoonsDir:   dirs.spoonsDir,
            stagingDir:  dirs.stagingDir,
            downloadURL: URL(string: "https://example.invalid/")!,
            downloader:  FixtureDownloader(zipURL: fixture))

        #expect(!bootstrap.isInstalled)
        try await bootstrap.ensureInstalled()
        #expect(bootstrap.isInstalled)

        // Init.lua we packed into the fixture made it through.
        let initLua = bootstrap.destination
            .appendingPathComponent("init.lua")
        let content = try String(contentsOf: initLua, encoding: .utf8)
        #expect(content.contains("FIXTURE_MARKER"))
    }

    @Test
    func staleDestinationIsReplacedOnReinstall() async throws {
        let dirs = try makeDirs()
        defer { cleanup(dirs) }
        // Plant a half-broken SpoonInstall.spoon (no init.lua) at the
        // destination — simulating a previous failed install.
        let dest = dirs.spoonsDir
            .appendingPathComponent("SpoonInstall.spoon")
        try FileManager.default.createDirectory(
            at: dest, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(
            to: dest.appendingPathComponent("garbage.txt"))

        let fixture = try makeFixtureZip(in: dirs.workDir)
        let bootstrap = SpoonInstallBootstrap(
            spoonsDir:   dirs.spoonsDir,
            stagingDir:  dirs.stagingDir,
            downloadURL: URL(string: "https://example.invalid/")!,
            downloader:  FixtureDownloader(zipURL: fixture))

        // ensureInstalled SHOULD detect the bad state (no init.lua)
        // and re-install.
        #expect(!bootstrap.isInstalled)
        try await bootstrap.ensureInstalled()
        #expect(bootstrap.isInstalled)
        // Garbage from the bad install is gone.
        #expect(!FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("garbage.txt").path))
    }

    @Test
    func downloadFailurePropagates() async throws {
        let dirs = try makeDirs()
        defer { cleanup(dirs) }
        let downloader = FixtureDownloader(
            zipURL: dirs.workDir.appendingPathComponent("nope.zip"))
        downloader.failOnDownload = true
        let bootstrap = SpoonInstallBootstrap(
            spoonsDir:   dirs.spoonsDir,
            stagingDir:  dirs.stagingDir,
            downloadURL: URL(string: "https://example.invalid/")!,
            downloader:  downloader)

        await #expect(throws: URLError.self) {
            try await bootstrap.ensureInstalled()
        }
        #expect(!bootstrap.isInstalled)
    }

    @Test
    func unexpectedZipLayoutThrowsCleanly() async throws {
        // Build a zip whose contents are NOT a top-level SpoonInstall.spoon
        // dir. The bootstrap should detect this and refuse rather than
        // moving a random file into ~/.hammerspoon/Spoons.
        let dirs = try makeDirs()
        defer { cleanup(dirs) }
        let badZip = try makeBadFixtureZip(in: dirs.workDir)
        let bootstrap = SpoonInstallBootstrap(
            spoonsDir:   dirs.spoonsDir,
            stagingDir:  dirs.stagingDir,
            downloadURL: URL(string: "https://example.invalid/")!,
            downloader:  FixtureDownloader(zipURL: badZip))

        await #expect(throws: BootstrapError.self) {
            try await bootstrap.ensureInstalled()
        }
        #expect(!bootstrap.isInstalled)
    }

    // MARK: - Helpers

    struct TestDirs {
        var workDir:    URL
        var spoonsDir:  URL
        var stagingDir: URL
    }

    private func makeDirs() throws -> TestDirs {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bootstrap-\(UUID().uuidString)")
        let spoons  = root.appendingPathComponent("Spoons")
        let staging = root.appendingPathComponent("staging")
        let work    = root.appendingPathComponent("work")
        for dir in [spoons, staging, work] {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        return TestDirs(workDir: work, spoonsDir: spoons, stagingDir: staging)
    }

    private func cleanup(_ dirs: TestDirs) {
        try? FileManager.default.removeItem(
            at: dirs.workDir.deletingLastPathComponent())
    }

    /// Build a tiny fixture zip whose contents are a top-level
    /// `SpoonInstall.spoon/` dir with an `init.lua` marker file.
    private func makeFixtureZip(in workDir: URL) throws -> URL {
        let spoonDir = workDir.appendingPathComponent("SpoonInstall.spoon")
        try FileManager.default.createDirectory(
            at: spoonDir, withIntermediateDirectories: true)
        try Data("-- FIXTURE_MARKER\n".utf8).write(
            to: spoonDir.appendingPathComponent("init.lua"))

        let zipPath = workDir.appendingPathComponent("SpoonInstall.spoon.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workDir
        process.arguments = ["-q", "-r", zipPath.path, "SpoonInstall.spoon"]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "test.zip", code: Int(process.terminationStatus))
        }
        return zipPath
    }

    /// Build a malformed zip whose contents are NOT a `SpoonInstall.spoon`
    /// dir — used to prove the bootstrap detects layout mismatch.
    private func makeBadFixtureZip(in workDir: URL) throws -> URL {
        let badDir = workDir.appendingPathComponent("WrongName")
        try FileManager.default.createDirectory(
            at: badDir, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: badDir.appendingPathComponent("x.txt"))
        let zipPath = workDir.appendingPathComponent("Wrong.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workDir
        process.arguments = ["-q", "-r", zipPath.path, "WrongName"]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "test.zip", code: Int(process.terminationStatus))
        }
        return zipPath
    }
}
