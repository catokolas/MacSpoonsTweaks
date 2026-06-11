import SwiftUI
import MacSpoonsTweaksKit

/// "View changes" modal for a Spoon with an available update. Loads a
/// `SpoonChangelog` on appear, shows commits between the user's
/// version and the latest, and offers an Update-now shortcut that
/// dismisses the sheet and triggers the host's `installNow()` path.
struct WhatsChangedSheet: View {
    let entry: SpoonCatalogEntry
    let onUpdate: () -> Void

    @EnvironmentObject private var catalog: SpoonCatalogModel
    @Environment(\.dismiss) private var dismiss

    @State private var state: LoadState = .loading

    enum LoadState {
        case loading
        case loaded(SpoonChangelog)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 620, height: 500)
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.title2.bold())
                rangeText
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    @ViewBuilder
    private var rangeText: some View {
        switch state {
        case .loading:
            Text("Loading changes…")
        case .loaded(let log):
            if log.precise,
               case .gitCommit(let i)? = installedRef,
               case .gitCommit(let l)? = latestRef {
                Text("From \(short(i)) → \(short(l))")
                    .font(.subheadline.monospaced())
            } else if !log.commits.isEmpty {
                Text("Recent commits")
            } else {
                Text("No new commits found")
            }
        case .failed:
            Text("Couldn't load changes")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let log):
            loaded(log)
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 10) {
                Text("Couldn't load changes")
                    .font(.headline).foregroundStyle(.red)
                Text(msg)
                    .font(.caption)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func loaded(_ log: SpoonChangelog) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note = log.note {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                    Text(note)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.orange.opacity(0.08)))
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            if log.commits.isEmpty {
                Text("No new commits touching this Spoon.")
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(log.commits) { commit in
                            CommitRow(commit: commit)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if case .loaded(let log) = state, let url = log.compareURL {
                Link("View on GitHub", destination: url)
                    .font(.callout)
            }
            Spacer()
            Button("Update now") {
                onUpdate()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Helpers

    private var installedRef: InstalledRef? {
        return catalog.installedRefSnapshot(for: entry)
    }
    private var latestRef: InstalledRef? {
        return catalog.latestRefs[entry.name]
    }

    private func short(_ sha: String) -> String {
        return String(sha.prefix(8))
    }

    private func load() async {
        state = .loading
        do {
            let log = try await catalog.changelog(for: entry)
            state = .loaded(log)
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

private struct CommitRow: View {
    let commit: SpoonCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.subject)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(commit.author)
                Text("·")
                Text(commit.date,
                     format: .relative(presentation: .named))
                Text("·")
                Link(String(commit.sha.prefix(8)),
                     destination: commit.url)
                    .font(.caption.monospaced())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}
