import AppKit

/// Keeps the process alive after the user closes the main window so the
/// `MenuBarExtra` icon stays available. Without this, macOS terminates
/// the app on last-window-close — `MenuBarExtra` alone does NOT prevent
/// that.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
}
