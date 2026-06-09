import SwiftUI
import MacSpoonsTweaksKit

/// Top-of-window banner that surfaces the init.lua patch state. Shown
/// when the user's `~/.hammerspoon/init.lua` doesn't yet `require` our
/// generated snippet, with an "Add line" button that runs
/// `InitLuaPatcher.apply`. Also surfaces the symlink target and
/// git-tree warning so the user knows exactly which file we're about
/// to edit.
struct InitLuaBanner: View {
    @EnvironmentObject var catalog: SpoonCatalogModel

    var body: some View {
        Group {
            switch catalog.initLuaPatchState {
            case .needsPatch(let plan): needsPatch(plan)
            case .justApplied:          appliedConfirmation
            case .failed(let msg):      failureBanner(msg)
            case .checking, .alreadyApplied, .dismissed:
                EmptyView()
            }
        }
    }

    // MARK: - States

    private func needsPatch(_ plan: PatchPlan) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(.orange)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 4) {
                Text("init.lua needs `require(\"mac_spoons_tweaks\")`")
                    .font(.headline)
                Text(needsPatchSubtitle(plan))
                    .font(.caption).foregroundStyle(.secondary)
                if plan.isSymlink {
                    Label {
                        Text("Symlink → \(plan.resolvedPath.path)")
                            .font(.caption2)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "arrow.right.square")
                    }
                    .foregroundStyle(.secondary)
                }
                if plan.isInGitTree {
                    Label {
                        Text("Heads up: the target file is in a git repo.")
                            .font(.caption2)
                    } icon: {
                        Image(systemName: "checkerboard.rectangle")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Button("Dismiss") { catalog.dismissInitLuaBanner() }
                Button("Add line") {
                    Task { await catalog.applyInitLuaPatch() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12))
    }

    private func needsPatchSubtitle(_ plan: PatchPlan) -> String {
        if plan.backupPath != nil {
            return "We'll back up the current file before appending the line."
        }
        return "We'll create init.lua and add the line."
    }

    private var appliedConfirmation: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("Added `require(\"mac_spoons_tweaks\")` to init.lua. " +
                 "Reload Hammerspoon for it to take effect.")
                .font(.subheadline)
            Spacer()
        }
        .padding(12)
        .background(.green.opacity(0.12))
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't patch init.lua")
                    .font(.headline)
                Text(message)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            Spacer()
            Button("Dismiss") { catalog.dismissInitLuaBanner() }
        }
        .padding(12)
        .background(.red.opacity(0.12))
    }
}
