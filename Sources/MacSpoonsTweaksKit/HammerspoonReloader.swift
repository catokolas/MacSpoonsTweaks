import Foundation

/// Tell the running Hammerspoon to reload its config. Uses AppleScript
/// rather than the `hs` CLI, so it works when `hs.ipc` hasn't been
/// loaded yet — i.e. exactly the fresh-install state where the
/// message-port-based bridge fails with "can't access Hammerspoon
/// message port".
///
/// Two notes on the AppleScript shape:
///
/// 1. **Verb.** Hammerspoon does NOT expose `reload` as a top-level
///    AppleScript command — `tell application "Hammerspoon" to reload`
///    errors with "The variable reload not defined" *before* the
///    AppleEvent is dispatched, which means macOS never registers the
///    Automation attempt and the user's permission prompt never fires.
///    Hammerspoon's actual public dictionary entry is
///    `execute lua code "…"` — that's a real verb, gets dispatched as
///    an AppleEvent, and triggers the standard "MacSpoonsTweaks wants
///    to control Hammerspoon" prompt on first use.
///
/// 2. **Deferred reload.** Calling `hs.reload()` synchronously from
///    AppleScript would tear down Hammerspoon while the AppleEvent
///    reply is still in flight. Wrapping in `hs.timer.doAfter(0.01,
///    …)` lets AppleScript return cleanly first; Hammerspoon then
///    reloads itself ~10 ms later.
///
/// Best-effort and non-blocking. Failures (Hammerspoon not running,
/// Automation permission denied, NSAppleScript compile error) are
/// silent by design — the caller's main flow continues unaffected,
/// and the launch-time bridge probe will surface a banner if a
/// subsequent Install still can't reach the message port.
public enum HammerspoonReloader {

    /// Type for the closure form, suitable for dependency injection
    /// (orchestrator + tests).
    public typealias Reload = @Sendable () -> Void

    /// The production reload action. Uses `NSAppleScript` (not
    /// `osascript` via `Process`), so the AppleEvent is dispatched
    /// from MST's own process and macOS attributes the Automation
    /// permission to MST itself — that's what makes the first-launch
    /// prompt fire cleanly.
    public static let appleScript: Reload = {
        let source =
            "tell application \"Hammerspoon\" to execute lua code " +
            "\"hs.timer.doAfter(0.01, function() hs.reload() end)\""
        // NSAppleScript.executeAndReturnError must run on the main
        // thread. Hop to main and fire-and-forget; we don't need to
        // wait for the AppleEvent reply.
        DispatchQueue.main.async {
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            _ = script.executeAndReturnError(&error)
        }
    }

    /// No-op variant for tests. Pass to `SpoonOrchestrator(reloader:)`
    /// so unit tests don't fire AppleEvents on every snippet write.
    public static let noOp: Reload = { }
}
