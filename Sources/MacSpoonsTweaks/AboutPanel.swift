import AppKit
import SwiftUI

/// Custom About panel — replaces the default SwiftUI/AppKit one so we
/// can size the window generously and lay the credits out without the
/// stock panel's cramped scroll view. Reuses a single window across
/// multiple About clicks.
enum AboutPanel {

    private static var window: NSWindow?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            existing.center()
            return
        }
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        panel.title = "About MacSpoonsTweaks"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(
            rootView: AboutContentView()
                .environment(\.dynamicTypeSize, .xLarge))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }
}

private struct AboutContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            blurb
            Divider()
            catalogs
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 560, height: 460, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("MacSpoonsTweaks")
                    .font(.title.bold())
                Text("Version \(versionString)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var blurb: some View {
        Text("A SwiftUI companion for Hammerspoon Spoons. Browse the "
           + "catalog, install Spoons, edit their typed config and "
           + "hotkeys, and push changes live — without hand-writing "
           + "init.lua. Apply persists state, regenerates "
           + "~/.hammerspoon/mac_spoons_tweaks.lua, then drives the "
           + "Spoon over the hs CLI so changes take effect immediately.")
            .font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var catalogs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spoon catalogs")
                .font(.headline)
            CatalogRow(
                title: "catokolas — curated Spoons + override manifests",
                url:   "https://github.com/catokolas/HS_SpoonsContrib")
            CatalogRow(
                title: "Hammerspoon official — upstream collection",
                url:   "https://github.com/Hammerspoon/Spoons")
        }
    }

    private var footer: some View {
        Text(copyrightString)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    private var copyrightString: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? "© Cato Kolås. Released under the MIT License."
    }
}

private struct CatalogRow: View {
    let title: String
    let url:   String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("•  \(title)")
                .font(.body)
            Link(url, destination: URL(string: url)!)
                .font(.body.monospaced())
                .padding(.leading, 18)
        }
    }
}
