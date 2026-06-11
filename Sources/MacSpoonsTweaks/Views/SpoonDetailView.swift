import SwiftUI
import MacSpoonsTweaksKit

/// Per-Spoon detail panel: header, config form, hotkey rows, action
/// footer. Seeds local @State from `orchestrator.seedState` on appear
/// so previously saved edits show up when re-opening a Spoon.
struct SpoonDetailView: View {
    let entry: SpoonCatalogEntry

    @EnvironmentObject var catalog: SpoonCatalogModel

    /// User edits, keyed by ConfigField.key. Seeded from state.json
    /// on appear via `orchestrator.seedState`. The form falls back to
    /// manifest defaults for any missing slot.
    @State private var values: [String: ConfigValue] = [:]

    /// User-recorded hotkey overrides, keyed by HotkeyAction.action.
    /// Absent → use manifest default.
    @State private var hotkeyOverrides: [String: HotkeyBinding] = [:]

    @State private var applyState: ApplyState = .idle
    @State private var applyMessage: String? = nil

    @State private var installState: InstallActionState = .idle
    @State private var changesShown: Bool                = false
    @State private var installMessage: String? = nil

    enum ApplyState: Equatable {
        case idle
        case inFlight
        case appliedOK
        case appliedWithLiveErrors
        case failed
    }

    enum InstallActionState: Equatable {
        case idle
        case installing
        case removing
        case failed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                installStateBar
                provenanceNote
                if !entry.knownIssues.isEmpty {
                    Divider()
                    KnownIssuesSection(issues: entry.knownIssues)
                }
                if !entry.optionalModules.isEmpty {
                    Divider()
                    OptionalModulesSection(modules: entry.optionalModules)
                }
                Divider()
                configSection
                if !entry.hotkeys.isEmpty {
                    Divider()
                    hotkeySection
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            footer
        }
        // Seed on first appear and whenever the user switches Spoons.
        .onAppear { seedFromState() }
        .onChange(of: entry.id) { _, _ in seedFromState() }
        .sheet(isPresented: $changesShown) {
            WhatsChangedSheet(entry: entry) {
                Task { await installNow() }
            }
        }
    }

    private func seedFromState() {
        let (config, hotkeys) =
            catalog.orchestrator.seedState(for: entry.name)
        values          = config
        hotkeyOverrides = hotkeys
        applyState      = .idle
        applyMessage    = nil
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.name).font(.title2).fontWeight(.semibold)
            HStack(spacing: 6) {
                Text("v\(entry.metadata.version)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text(entry.sourceID)
                    .font(.subheadline).foregroundStyle(.secondary)
                if let homepage = entry.metadata.homepage,
                   let url = URL(string: homepage) {
                    Text("·").foregroundStyle(.secondary)
                    Link("Homepage", destination: url)
                        .font(.subheadline)
                }
            }
            if let desc = entry.metadata.description {
                Text(desc).font(.body).padding(.top, 4)
            }
        }
    }

    private var installStateBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                stateBadge
                Spacer()
                installActionButton
            }
            if let msg = installMessage, installState == .failed {
                Text(msg).font(.caption).foregroundStyle(.red)
                    .lineLimit(3).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.gray.opacity(0.08)))
    }

    private var stateBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: stateBadgeIcon)
                .foregroundStyle(stateBadgeColor)
            Text(stateBadgeLabel)
                .font(.subheadline)
        }
    }

    private var stateBadgeIcon: String {
        switch installState {
        case .installing, .removing: return "arrow.triangle.2.circlepath"
        case .failed:                return "exclamationmark.triangle.fill"
        case .idle:
            if !catalog.isInstalled(entry) { return "arrow.down.circle" }
            return catalog.updateAvailable(for: entry)
                ? "arrow.down.app.fill"
                : "checkmark.circle.fill"
        }
    }

    private var stateBadgeColor: Color {
        switch installState {
        case .installing, .removing: return .accentColor
        case .failed:                return .red
        case .idle:
            if !catalog.isInstalled(entry) { return .secondary }
            return catalog.updateAvailable(for: entry) ? .orange : .green
        }
    }

    private var stateBadgeLabel: String {
        switch installState {
        case .installing: return "Installing…"
        case .removing:   return "Removing…"
        case .failed:     return "Last action failed"
        case .idle:
            if !catalog.isInstalled(entry) { return "Not installed" }
            return catalog.updateAvailable(for: entry)
                ? "Update available"
                : "Installed in ~/.hammerspoon/Spoons"
        }
    }

    @ViewBuilder
    private var installActionButton: some View {
        if installState == .installing || installState == .removing {
            ProgressView().controlSize(.small)
        } else if catalog.isInstalled(entry) {
            HStack(spacing: 6) {
                if catalog.updateAvailable(for: entry) {
                    // Install reuses the installer's path — it
                    // overwrites in place, which is what Update wants.
                    Button("Update") { Task { await installNow() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    Button("View changes") { changesShown = true }
                        .buttonStyle(.bordered)
                        .help("Preview the commits between your installed version and the latest before updating.")
                }
                Button("Remove") { Task { await removeNow() } }
                    .tint(.red)
            }
        } else {
            Button("Install") { Task { await installNow() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private func installNow() async {
        installState   = .installing
        installMessage = nil
        do {
            try await catalog.install(entry)
            installState = .idle
        } catch {
            installState   = .failed
            installMessage = String(describing: error)
        }
    }

    private func removeNow() async {
        installState   = .removing
        installMessage = nil
        do {
            try await catalog.remove(entry)
            installState = .idle
        } catch {
            installState   = .failed
            installMessage = String(describing: error)
        }
    }

    private var provenanceNote: some View {
        HStack(spacing: 6) {
            Image(systemName: provenanceIcon)
            Text(provenanceLabel)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Configuration").font(.headline)
                Spacer()
            }
            driftNotice
            if entry.config.isEmpty {
                Text("This Spoon has no documented configuration.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ConfigFormView(fields: entry.config, values: $values)
            }
        }
    }

    @ViewBuilder
    private var driftNotice: some View {
        let drift = catalog.catalogDrift(for: entry)
        if !drift.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Catalog updated since install")
                        .font(.subheadline)
                }
                if !drift.addedKeys.isEmpty {
                    Text("New: \(drift.addedKeys.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !drift.removedKeys.isEmpty {
                    Text("Removed: \(drift.removedKeys.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.blue.opacity(0.1)))
        }
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hotkeys").font(.headline)
            ForEach(entry.hotkeys) { action in
                VStack(alignment: .leading, spacing: 4) {
                    HotkeyRecorderField(
                        actionLabel: action.label ?? action.action,
                        default: action.default,
                        binding: Binding<HotkeyBinding?>(
                            get: { hotkeyOverrides[action.action] },
                            set: { newValue in
                                if let v = newValue {
                                    hotkeyOverrides[action.action] = v
                                } else {
                                    hotkeyOverrides[action.action] = nil
                                }
                            }))
                    conflictNotice(for: action)
                }
            }
        }
    }

    @ViewBuilder
    private func conflictNotice(for action: HotkeyAction) -> some View {
        let me = HotkeyConflict.Participant(
            spoonName: entry.name, actionName: action.action)
        let others: [HotkeyConflict.Participant] = catalog.hotkeyConflicts
            .filter { $0.participants.contains(me) }
            .flatMap { $0.participants }
            .filter { $0 != me }
        if !others.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
                Text("Same chord as \(formatParticipants(others))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .padding(.leading, 4)
        }
    }

    private func formatParticipants(
        _ ps: [HotkeyConflict.Participant]
    ) -> String {
        let unique = Array(Set(ps))
            .sorted { ($0.spoonName, $0.actionName)
                      < ($1.spoonName, $1.actionName) }
        let labels = unique.map { "\($0.spoonName).\($0.actionName)" }
        return labels.joined(separator: ", ")
    }

    private var footer: some View {
        VStack(spacing: 6) {
            applyStatusLine
            HStack {
                Button("Reset to defaults") {
                    values = [:]
                    hotkeyOverrides = [:]
                    applyState   = .idle
                    applyMessage = nil
                }
                .disabled(values.isEmpty && hotkeyOverrides.isEmpty
                          || applyState == .inFlight)
                if catalog.isInstalled(entry)
                    && entry.lifecycle.hasStart
                    && entry.lifecycle.hasStop {
                    let isPaused = catalog.isPaused(entry)
                    Toggle("Active", isOn: Binding(
                        get: { !isPaused },
                        set: { active in
                            Task { await togglePause(to: !active) }
                        }))
                    .toggleStyle(.switch)
                    .disabled(applyState == .inFlight)
                    .help(isPaused
                          ? "Deactivated — Spoon stays in the snippet but isn’t running. Toggle on to call :start()."
                          : "Active — Spoon is running. Toggle off to call :stop() and omit start = true from the snippet. Config and hotkeys are preserved.")
                }
                Spacer()
                Button {
                    Task { await applyNow() }
                } label: {
                    HStack(spacing: 6) {
                        if applyState == .inFlight {
                            ProgressView().controlSize(.small)
                        }
                        Text("Apply")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(applyState == .inFlight
                          || !catalog.isInstalled(entry))
                .help(catalog.isInstalled(entry)
                      ? "Save config + hotkeys, regenerate the snippet, and push live."
                      : "Install the Spoon first — Apply pushes config to the running Hammerspoon, which needs the Spoon present.")
            }
        }
        .padding()
        .background(.bar)
    }

    @ViewBuilder
    private var applyStatusLine: some View {
        switch applyState {
        case .appliedOK:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Applied — state saved and pushed live.")
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .appliedWithLiveErrors:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Saved, but live apply failed. Reload Hammerspoon to pick up the snippet.")
                }
                if let msg = applyMessage {
                    Text(msg).font(.caption2).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(applyMessage ?? "Apply failed.")
                    .textSelection(.enabled)
            }
            .font(.caption).foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .idle, .inFlight:
            EmptyView()
        }
    }

    private func applyNow() async {
        applyState = .inFlight
        applyMessage = nil
        do {
            let result = try await catalog.orchestrator.apply(
                entry:           entry,
                values:          values,
                hotkeyOverrides: hotkeyOverrides)
            // Apply may have changed effective bindings — re-check
            // for conflicts so the sidebar chip and per-row warning
            // both reflect the new state.
            catalog.recomputeHotkeyConflicts()
            if result.liveAppliedOK {
                applyState = .appliedOK
            } else {
                applyState   = .appliedWithLiveErrors
                applyMessage = result.liveApplyError
            }
        } catch {
            applyState   = .failed
            applyMessage = String(describing: error)
        }
    }

    private func togglePause(to paused: Bool) async {
        applyState = .inFlight
        applyMessage = nil
        do {
            let result = try await catalog.setPaused(entry, paused)
            if result.liveAppliedOK {
                applyState = .appliedOK
            } else {
                applyState   = .appliedWithLiveErrors
                applyMessage = result.liveApplyError
            }
        } catch {
            applyState   = .failed
            applyMessage = String(describing: error)
        }
    }

    // MARK: - Helpers

    private var provenanceIcon: String {
        switch entry.provenance {
        case .manifest:       return "checkmark.seal"
        case .override:       return "wand.and.stars"
        case .inferred:       return "questionmark.diamond"
        }
    }

    private var provenanceLabel: String {
        switch entry.provenance {
        case .manifest:       return "Schema authored in this project"
        case .override(let s): return "Curated override for \(s)"
        case .inferred:       return "Inferred from docs.json (best-effort)"
        }
    }

}
