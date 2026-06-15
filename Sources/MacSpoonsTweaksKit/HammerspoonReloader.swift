import Foundation

/// Tell the running Hammerspoon to reload its config. Crucially, this
/// uses AppleScript (not the `hs` CLI), so it works when `hs.ipc`
/// hasn't been loaded yet — i.e. exactly the fresh-install state
/// where the message-port-based bridge fails with
/// "can't access Hammerspoon message port".
///
/// Best-effort and non-blocking. A failed reload (Hammerspoon not
/// running, AppleScript permission denied, osascript missing) is
/// logged and swallowed; the caller's main flow continues unaffected.
public enum HammerspoonReloader {

    /// Type for the closure form, suitable for dependency injection
    /// (orchestrator + tests).
    public typealias Reload = @Sendable () -> Void

    /// The production reload action: launches `osascript` with a one-
    /// line `tell application "Hammerspoon" to reload`. Does NOT wait
    /// for Hammerspoon to come back — reload is fast and idempotent.
    public static let appleScript: Reload = {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"Hammerspoon\" to reload"]
        // Suppress osascript's stderr; we don't care if Hammerspoon
        // isn't running or AppleScript isn't allowed.
        task.standardError  = Pipe()
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            // No log channel down here; failure is silent by design.
        }
    }

    /// No-op variant for tests. Pass to `SpoonOrchestrator(reloader:)`
    /// so unit tests don't fork osascript on every snippet write.
    public static let noOp: Reload = { }
}
