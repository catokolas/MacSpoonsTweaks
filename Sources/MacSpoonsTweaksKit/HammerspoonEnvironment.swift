import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Snapshot of the local Hammerspoon installation state. Drives the
/// status bar in the app, the bootstrap decisions for SpoonInstall,
/// and whether the bridge can perform a live apply.
public struct HammerspoonStatus: Equatable, Sendable {
    /// `/Applications/Hammerspoon.app` exists.
    public var appInstalled: Bool

    /// A process with bundle ID `org.hammerspoon.Hammerspoon` is running.
    public var appRunning: Bool

    /// Resolved path to the `hs` CLI, or `nil` if Command Line Tool isn't
    /// installed via Hammerspoon → Preferences → "Install Command Line
    /// Tool". Probed at `/opt/homebrew/bin/hs` (Apple Silicon) first,
    /// then `/usr/local/bin/hs` (Intel). The app's `$PATH` is not trusted
    /// because launchd-spawned apps inherit a sandbox-style minimal PATH.
    public var cliPath: URL?

    /// `~/.hammerspoon`. Always present at this path even if the dir
    /// hasn't been created yet — the caller decides whether to create
    /// it on first use.
    public var configDir: URL

    /// `~/.hammerspoon/Spoons`.
    public var spoonsDir: URL

    /// `~/.hammerspoon/init.lua`.
    public var initLuaPath: URL

    /// `~/.hammerspoon/Spoons/SpoonInstall.spoon/init.lua` exists.
    public var spoonInstallPresent: Bool

    /// Sentinel for "we can talk to a live Hammerspoon and run scripts."
    public var canRunLua: Bool { appRunning && cliPath != nil }
}

// MARK: - Probe abstraction

/// Hook points that the real environment hits at the operating-system
/// level. Splitting these out lets tests inject a deterministic probe
/// without going near AppKit or the real filesystem.
public protocol HammerspoonProbe: Sendable {
    /// `/Applications/Hammerspoon.app` exists.
    func isAppInstalled() -> Bool

    /// A running NSRunningApplication has bundle ID
    /// `org.hammerspoon.Hammerspoon`.
    func isAppRunning() -> Bool

    /// First-found executable hs CLI. Probes the standard Homebrew
    /// locations directly because `$PATH` isn't reliable for a Mac app.
    func findCLIPath() -> URL?

    /// File-existence check at a known path.
    func fileExists(at: URL) -> Bool

    /// `~` for the current user.
    var homeDirectory: URL { get }
}

// MARK: - Default (production) probe

public struct SystemHammerspoonProbe: HammerspoonProbe {
    public init() {}

    public func isAppInstalled() -> Bool {
        return FileManager.default.fileExists(
            atPath: "/Applications/Hammerspoon.app")
    }

    public func isAppRunning() -> Bool {
        #if canImport(AppKit)
        return NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == "org.hammerspoon.Hammerspoon"
        }
        #else
        return false
        #endif
    }

    public func findCLIPath() -> URL? {
        // Apple-Silicon Homebrew first, then Intel. Hammerspoon symlinks
        // its `hs` shim into one of these when the user enables the CLI
        // tool via the Hammerspoon menu.
        let candidates = ["/opt/homebrew/bin/hs", "/usr/local/bin/hs"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func fileExists(at url: URL) -> Bool {
        return FileManager.default.fileExists(atPath: url.path)
    }

    public var homeDirectory: URL {
        // `FileManager.homeDirectoryForCurrentUser` returns the SANDBOX
        // container home in a sandboxed app — we want the real one.
        // `NSHomeDirectory()` returns the same; both are fine while the
        // app is unsandboxed (the planned distribution path).
        return URL(fileURLWithPath: NSHomeDirectory())
    }
}

// MARK: - Environment

public struct HammerspoonEnvironment: Sendable {
    public let probe: any HammerspoonProbe

    public init(probe: any HammerspoonProbe = SystemHammerspoonProbe()) {
        self.probe = probe
    }

    /// Produce a fresh snapshot. Cheap — all probes are local stat-style
    /// calls.
    public func snapshot() -> HammerspoonStatus {
        let home = probe.homeDirectory
        let configDir = home.appendingPathComponent(".hammerspoon")
        let spoonsDir = configDir.appendingPathComponent("Spoons")
        let initLua   = configDir.appendingPathComponent("init.lua")
        let spoonInstallInit = spoonsDir
            .appendingPathComponent("SpoonInstall.spoon")
            .appendingPathComponent("init.lua")
        return HammerspoonStatus(
            appInstalled: probe.isAppInstalled(),
            appRunning:   probe.isAppRunning(),
            cliPath:      probe.findCLIPath(),
            configDir:    configDir,
            spoonsDir:    spoonsDir,
            initLuaPath:  initLua,
            spoonInstallPresent: probe.fileExists(at: spoonInstallInit)
        )
    }
}
