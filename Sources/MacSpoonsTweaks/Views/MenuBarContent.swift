import SwiftUI
import AppKit
import MacSpoonsTweaksKit

/// Pull-down menu rendered inside the `MenuBarExtra`. Lives in a `View`
/// rather than the `Scene` because `@Environment(\.openWindow)` is only
/// available in `View` scope.
struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var catalog: SpoonCatalogModel

    var body: some View {
        // Grayed-out header. `Text` doesn't render as a menu row in
        // `.menu` style — `Button(...).disabled(true)` does.
        Button("MacSpoonsTweaks") {}
            .disabled(true)

        Divider()

        Button("Settings…") {
            // Activate first so the window opens against an active app
            // (avoids the "opens behind frontmost" race on Sonoma).
            // `activate` also unhides if the user pressed Cmd-H.
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
            // openWindow no-ops on a minimized window — de-miniaturize
            // explicitly. SwiftUI auto-suffixes the underlying
            // NSWindow.identifier, so match by prefix not equality.
            for window in NSApp.windows
            where window.identifier?.rawValue.contains("main") == true
                && window.isMiniaturized {
                window.deminiaturize(nil)
            }
        }

        pauseSubmenu

        Divider()

        Button("Exit") {
            NSApplication.shared.terminate(nil)
        }
    }

    @ViewBuilder
    private var pauseSubmenu: some View {
        // Every installed Spoon — checked = active.
        // For pausable Spoons (hasStart && hasStop) the toggle flips
        // `paused`; for the rest (AClock-style) it flips `enabled`.
        let togglable = catalog.toggleableInstalledSpoons()
        Menu("Active Spoons") {
            if togglable.isEmpty {
                Button("(no installed Spoons)") {}.disabled(true)
            } else {
                ForEach(togglable, id: \.id) { entry in
                    Toggle(entry.name, isOn: Binding(
                        get: { catalog.isActive(entry) },
                        set: { active in
                            Task {
                                try? await catalog.setActive(entry, active)
                            }
                        }))
                }
            }
        }
    }
}
