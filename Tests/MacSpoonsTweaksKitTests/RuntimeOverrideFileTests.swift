import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("RuntimeOverrideFile")
struct RuntimeOverrideFileTests {

    /// Tmp-dir helper — each test gets a fresh path so writes don't
    /// cross-contaminate.
    private func makeFile() -> (RuntimeOverrideFile, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rofile-\(UUID().uuidString)",
                                    isDirectory: true)
        try! FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("overrides.lua",
                                               isDirectory: false)
        return (RuntimeOverrideFile(path: path), path)
    }

    @Test
    func readReturnsEmptyForMissingFile() {
        let (f, _) = makeFile()
        #expect(f.read().isEmpty)
    }

    @Test
    func writeThenReadRoundTrips() throws {
        let (f, _) = makeFile()
        try f.write(["FocusFollowsMouse", "MouseScrollTweaks"])
        let got = f.read()
        #expect(got == ["FocusFollowsMouse", "MouseScrollTweaks"])
    }

    @Test
    func emptySetWritesReturnBracesAndStaysOnDisk() throws {
        // The Swift-side watcher needs the file to exist between
        // chord toggles, so write([]) leaves a `return {}` body
        // rather than deleting.
        let (f, path) = makeFile()
        try f.write(["FocusFollowsMouse"])
        try f.write([])
        #expect(FileManager.default.fileExists(atPath: path.path))
        let body = (try? String(contentsOf: path)) ?? ""
        #expect(body.contains("return {"))
        #expect(f.read().isEmpty)
    }

    @Test
    func setDeactivatedTogglesSingleEntry() throws {
        let (f, _) = makeFile()
        try f.setDeactivated("FocusFollowsMouse", true)
        #expect(f.read() == ["FocusFollowsMouse"])
        try f.setDeactivated("MouseScrollTweaks", true)
        #expect(f.read() == ["FocusFollowsMouse", "MouseScrollTweaks"])
        try f.setDeactivated("FocusFollowsMouse", false)
        #expect(f.read() == ["MouseScrollTweaks"])
    }

    @Test
    func parserIgnoresCommentsAndExtraWhitespace() throws {
        // Mirrors what the Lua-side writer in the snippet emits.
        let (f, path) = makeFile()
        let body = """
        -- mac_spoons_tweaks_overrides.lua - MANAGED FILE - DO NOT EDIT.
        return {
          FocusFollowsMouse = true,
            MouseTrackpadTweaks = true,
        }
        """
        try body.write(to: path, atomically: true, encoding: .utf8)
        #expect(f.read() == ["FocusFollowsMouse", "MouseTrackpadTweaks"])
    }

    @Test
    func parserIgnoresMalformedRows() throws {
        let (f, path) = makeFile()
        // Junk values, missing equals, non-identifier keys — all
        // silently dropped so a one-off bad line doesn't poison the
        // remaining entries.
        let body = """
        return {
          FocusFollowsMouse = true,
          weird/name = true,
          NoEqualsHere,
          NotTrue = false,
          MouseScrollTweaks = true,
        }
        """
        try body.write(to: path, atomically: true, encoding: .utf8)
        #expect(f.read() == ["FocusFollowsMouse", "MouseScrollTweaks"])
    }

    @Test
    func ensureExistsCreatesEmptyFile() throws {
        let (f, path) = makeFile()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        try f.ensureExists()
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(f.read().isEmpty)
        // Idempotent: second call doesn't blow up.
        try f.ensureExists()
        #expect(FileManager.default.fileExists(atPath: path.path))
    }
}
