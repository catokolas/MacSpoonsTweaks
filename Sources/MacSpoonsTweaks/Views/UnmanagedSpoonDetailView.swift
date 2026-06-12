import SwiftUI
import AppKit
import MacSpoonsTweaksKit

/// Detail panel for a Spoon the app didn't install. Shows the
/// on-disk path, symlink resolution, and a couple of inspection
/// actions — no config form (we don't know its schema).
struct UnmanagedSpoonDetailView: View {
    let spoon: UnmanagedSpoon

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusBar
                metadataSection
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(spoon.name)
                .scaledFont(.largeTitle).fontWeight(.semibold)
            Text("Externally managed Spoon")
                .scaledFont(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: spoon.isSymlink
                  ? "link.circle.fill"
                  : "folder.circle.fill")
                .foregroundStyle(spoon.isSymlink ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(spoon.isSymlink
                     ? "Symlink in ~/.hammerspoon/Spoons"
                     : "Plain directory in ~/.hammerspoon/Spoons")
                    .scaledFont(.subheadline)
                Text("Installed outside Mac Spoons Tweaks — not tracked.")
                    .scaledFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([spoon.path])
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.gray.opacity(0.08)))
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Path").scaledFont(.headline)
            Text(spoon.path.path)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            if let target = spoon.symlinkTarget {
                Text("Symlink target").scaledFont(.headline).padding(.top, 6)
                Text(target.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 6)
            Text("Why is this here?").scaledFont(.headline)
            Text(explanation)
                .scaledFont(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var explanation: String {
        if spoon.isSymlink {
            return "A symlink at \(spoon.path.lastPathComponent) points at a Spoon "
                 + "you (or another tool) installed manually. Mac Spoons Tweaks "
                 + "won't touch it. To bring it under management, delete the symlink "
                 + "and install the same-named Spoon from the catalog above."
        } else {
            return "A regular Spoon directory the app didn't install. It will keep "
                 + "working in Hammerspoon, but Mac Spoons Tweaks doesn't know its "
                 + "config schema or origin, so the per-Spoon UI is unavailable."
        }
    }
}
