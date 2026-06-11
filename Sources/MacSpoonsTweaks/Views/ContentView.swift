import SwiftUI
import MacSpoonsTweaksKit

struct ContentView: View {
    @EnvironmentObject var catalog: SpoonCatalogModel
    @State private var selection:    SpoonCatalogEntry.ID?
    @State private var searchText:   String        = ""
    @State private var sourceFilter: SourceFilter  = .all
    @State private var diagnosticsShown: Bool       = false
    @State private var catalogsShown:    Bool       = false

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all      = "All"
        case ours     = "catokolas"
        case official = "Official"
        var id: String { rawValue }

        /// Matches a Spoon's sourceID against the filter.
        func matches(_ sourceID: String) -> Bool {
            switch self {
            case .all:      return true
            case .ours:     return sourceID == "catokolas"
            case .official: return sourceID == "hammerspoon-official"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            InitLuaBanner()
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            } detail: {
                detail
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .task { catalog.refreshInitLuaPatchState() }
        .sheet(isPresented: $diagnosticsShown) {
            DiagnosticsView()
        }
        .sheet(isPresented: $catalogsShown) {
            ManageCatalogsView()
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        switch catalog.loadState {
        case .idle:
            ProgressView("Loading catalog…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where catalog.entries.isEmpty:
            ProgressView("Loading catalog…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed where catalog.entries.isEmpty:
            VStack(spacing: 8) {
                Text("Couldn’t load catalog")
                    .font(.headline)
                if let e = catalog.lastError {
                    Text(e).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Button("Retry") { Task { await catalog.refresh() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            sidebarLoaded
        }
    }

    private var sidebarLoaded: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()
            sidebarList
        }
    }

    private var sidebarHeader: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Spoons", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    Task { await catalog.checkForUpdates() }
                } label: {
                    if catalog.isCheckingForUpdates {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Check upstream for updates")
                .disabled(catalog.isCheckingForUpdates)
                Button {
                    catalogsShown = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Manage catalogs…")
                Button {
                    diagnosticsShown = true
                } label: {
                    Image(systemName: "stethoscope")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show bridge invocation diagnostics")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.gray.opacity(0.1)))

            Picker("Source", selection: $sourceFilter) {
                ForEach(SourceFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if !catalog.hotkeyConflicts.isEmpty {
                conflictChip
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var conflictChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
            Text("\(catalog.hotkeyConflicts.count) hotkey conflict" +
                 (catalog.hotkeyConflicts.count == 1 ? "" : "s"))
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.orange.opacity(0.15)))
        .help(conflictTooltip)
    }

    private var conflictTooltip: String {
        catalog.hotkeyConflicts
            .map { c in
                let chord = Hotkey.formatBinding(c.binding)
                let names = c.participants
                    .map { "\($0.spoonName).\($0.actionName)" }
                    .joined(separator: ", ")
                return "\(chord): \(names)"
            }
            .joined(separator: "\n")
    }

    @ViewBuilder
    private var sidebarList: some View {
        if filteredEntries.isEmpty && filteredUnmanaged.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text(noMatchHint))
        } else {
            List(selection: $selection) {
                ForEach(grouped, id: \.0) { groupName, items in
                    Section(groupName) {
                        ForEach(items) { entry in
                            SpoonRow(entry: entry).tag(entry.id)
                        }
                    }
                }
                if !filteredUnmanaged.isEmpty {
                    Section("Unmanaged") {
                        ForEach(filteredUnmanaged) { spoon in
                            UnmanagedSpoonRow(spoon: spoon)
                                .tag(unmanagedTag(spoon))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// Selection-ID prefix for unmanaged Spoons. Keeps them in the
    /// same `selection` slot as catalog entries while staying easy to
    /// disambiguate in the detail dispatcher.
    private static let unmanagedPrefix = "unmanaged:"

    private func unmanagedTag(_ spoon: UnmanagedSpoon) -> String {
        return Self.unmanagedPrefix + spoon.name
    }

    private var filteredUnmanaged: [UnmanagedSpoon] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
            .lowercased()
        // Source filter doesn't really apply — unmanaged Spoons have
        // no source. Hide them entirely when the user explicitly
        // narrowed to a single source so they don't get in the way of
        // a focused search.
        guard sourceFilter == .all else { return [] }
        return catalog.unmanagedSpoons.filter { spoon in
            needle.isEmpty || spoon.name.lowercased().contains(needle)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selection {
            if id.hasPrefix(Self.unmanagedPrefix) {
                let name = String(id.dropFirst(Self.unmanagedPrefix.count))
                if let s = catalog.unmanagedSpoons
                    .first(where: { $0.name == name }) {
                    UnmanagedSpoonDetailView(spoon: s)
                } else {
                    unselectedPlaceholder
                }
            } else if let entry = catalog.entries
                .first(where: { $0.id == id }) {
                SpoonDetailView(entry: entry)
            } else {
                unselectedPlaceholder
            }
        } else {
            unselectedPlaceholder
        }
    }

    private var unselectedPlaceholder: some View {
        ContentUnavailableView(
            "Select a Spoon",
            systemImage: "list.bullet.rectangle",
            description: Text(
                "Pick a Spoon from the sidebar to view its configuration."))
    }

    // MARK: - Filtering

    private var filteredEntries: [SpoonCatalogEntry] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
            .lowercased()
        return catalog.entries.filter { entry in
            guard sourceFilter.matches(entry.sourceID) else { return false }
            if needle.isEmpty { return true }
            if entry.name.lowercased().contains(needle) { return true }
            if let desc = entry.metadata.description,
               desc.lowercased().contains(needle) { return true }
            return false
        }
    }

    /// `[(sourceID-display-label, [entries])]` for a tidy two-section
    /// rendering when the user has "All" selected. With an explicit
    /// source filter we collapse to a single section.
    private var grouped: [(String, [SpoonCatalogEntry])] {
        let entries = filteredEntries
        switch sourceFilter {
        case .ours:
            return [("catokolas", entries)]
        case .official:
            return [("Hammerspoon official", entries)]
        case .all:
            let ours      = entries.filter { $0.sourceID == "catokolas" }
            let official  = entries.filter {
                $0.sourceID == "hammerspoon-official"
            }
            var out: [(String, [SpoonCatalogEntry])] = []
            if !ours.isEmpty     { out.append(("catokolas", ours)) }
            if !official.isEmpty { out.append(("Hammerspoon official", official)) }
            return out
        }
    }

    private var noMatchHint: String {
        if searchText.isEmpty { return "Try a different source filter." }
        return "No Spoons match “\(searchText)”."
    }
}

private struct UnmanagedSpoonRow: View {
    let spoon: UnmanagedSpoon

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: spoon.isSymlink ? "link" : "folder")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(spoon.name).font(.body)
                Text(spoon.isSymlink
                     ? "Externally managed (symlink)"
                     : "Externally managed")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SpoonRow: View {
    let entry: SpoonCatalogEntry
    @EnvironmentObject var catalog: SpoonCatalogModel

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.name).font(.body)
                    if catalog.isInstalled(entry) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .imageScale(.small)
                            .help("Installed")
                    }
                    if catalog.updateAvailable(for: entry) {
                        Image(systemName: "arrow.down.app.fill")
                            .foregroundStyle(.orange)
                            .imageScale(.small)
                            .help("Update available")
                    }
                    if !entry.knownIssues.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .imageScale(.small)
                            .help(
                                "Known issue: "
                                + entry.knownIssues
                                    .map(\.title)
                                    .joined(separator: "; "))
                    }
                }
                if let desc = entry.metadata.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// SpoonDetailView lives in Views/SpoonDetailView.swift now.
