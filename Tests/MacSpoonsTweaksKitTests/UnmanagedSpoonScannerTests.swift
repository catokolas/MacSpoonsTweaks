import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("UnmanagedSpoonScanner")
struct UnmanagedSpoonScannerTests {

    @Test
    func emptyDirectoryReturnsEmpty() throws {
        let dir = try makeTmp()
        defer { cleanup(dir) }
        let result = UnmanagedSpoonScanner.scan(spoonsDir: dir)
        #expect(result.isEmpty)
    }

    @Test
    func nonexistentDirectoryReturnsEmpty() {
        // No crash on a path that doesn't exist yet — first-run
        // scenario before ~/.hammerspoon is created.
        let result = UnmanagedSpoonScanner.scan(
            spoonsDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("nope-\(UUID().uuidString)"))
        #expect(result.isEmpty)
    }

    @Test
    func detectsPlainSpoonDirectory() throws {
        let dir = try makeTmp()
        defer { cleanup(dir) }
        try makeSpoon(named: "AClock", in: dir)
        let result = UnmanagedSpoonScanner.scan(spoonsDir: dir)
        #expect(result.count == 1)
        let s = result[0]
        #expect(s.name == "AClock")
        #expect(s.isSymlink == false)
        #expect(s.symlinkTarget == nil)
        #expect(s.path.lastPathComponent == "AClock.spoon")
    }

    @Test
    func detectsSymlinkedSpoonWithResolvedTarget() throws {
        let dir = try makeTmp()
        defer { cleanup(dir) }
        // Real target lives elsewhere.
        let realRoot = try makeTmp()
        defer { cleanup(realRoot) }
        let realSpoon = realRoot.appendingPathComponent("ClickThrough.spoon")
        try FileManager.default.createDirectory(
            at: realSpoon, withIntermediateDirectories: true)
        // Symlink at ~/.hammerspoon/Spoons/ClickThrough.spoon → real.
        let linkPath = dir.appendingPathComponent("ClickThrough.spoon")
        try FileManager.default.createSymbolicLink(
            at: linkPath, withDestinationURL: realSpoon)

        let result = UnmanagedSpoonScanner.scan(spoonsDir: dir)
        #expect(result.count == 1)
        #expect(result[0].isSymlink == true)
        // Resolved real path equals the real spoon dir.
        #expect(result[0].symlinkTarget?.path == realSpoon.path)
    }

    @Test
    func skipsNonSpoonNamedDirectories() throws {
        let dir = try makeTmp()
        defer { cleanup(dir) }
        try makeSpoon(named: "Real", in: dir)
        // Distractors that should be ignored.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("just-a-dir"),
            withIntermediateDirectories: true)
        try "stuff".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        let result = UnmanagedSpoonScanner.scan(spoonsDir: dir)
        #expect(result.map(\.name) == ["Real"])
    }

    @Test
    func skipsOwnedSpoonInstall() throws {
        // SpoonInstall.spoon is the bootstrap's responsibility — it
        // should never appear in the unmanaged list even if it's
        // somehow not represented in state.json.
        let dir = try makeTmp()
        defer { cleanup(dir) }
        try makeSpoon(named: "SpoonInstall", in: dir)
        try makeSpoon(named: "Visible", in: dir)
        let result = UnmanagedSpoonScanner.scan(spoonsDir: dir)
        #expect(result.map(\.name) == ["Visible"])
    }

    @Test
    func excludesManagedNames() throws {
        let dir = try makeTmp()
        defer { cleanup(dir) }
        try makeSpoon(named: "AClock",          in: dir)
        try makeSpoon(named: "FocusFollowsMouse", in: dir)
        // Caller already considers FocusFollowsMouse managed
        // (state.json says it's installed by us).
        let result = UnmanagedSpoonScanner.scan(
            spoonsDir: dir,
            excluding: ["FocusFollowsMouse"])
        #expect(result.map(\.name) == ["AClock"])
    }

    @Test
    func resultsAreSortedByName() throws {
        let dir = try makeTmp()
        defer { cleanup(dir) }
        try makeSpoon(named: "Zebra",  in: dir)
        try makeSpoon(named: "Alpha",  in: dir)
        try makeSpoon(named: "Mango",  in: dir)
        let result = UnmanagedSpoonScanner.scan(spoonsDir: dir)
        #expect(result.map(\.name) == ["Alpha", "Mango", "Zebra"])
    }

    // MARK: - Helpers

    private func makeTmp() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeSpoon(named name: String, in dir: URL) throws {
        let spoonDir = dir.appendingPathComponent("\(name).spoon")
        try FileManager.default.createDirectory(
            at: spoonDir, withIntermediateDirectories: true)
        try Data("-- placeholder init.lua".utf8).write(
            to: spoonDir.appendingPathComponent("init.lua"))
    }
}
