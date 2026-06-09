import SwiftUI
import MacSpoonsTweaksKit

@main
struct MacSpoonsTweaksApp: App {
    @StateObject private var catalog = SpoonCatalogModel()

    var body: some Scene {
        WindowGroup("Spoons") {
            ContentView()
                .environmentObject(catalog)
                .luaRunner(catalog.runner)
                .task { await catalog.refreshIfNeeded() }
        }
        .windowResizability(.contentSize)
    }
}

/// Lock-guarded snapshot of the catalog so the orchestrator's
/// `@Sendable` provider closures can read it from any actor.
private final class CatalogCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: SpoonCatalogEntry] = [:]

    func update(_ new: [String: SpoonCatalogEntry]) {
        lock.lock(); defer { lock.unlock() }
        entries = new
    }

    func read() -> [String: SpoonCatalogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

@MainActor
final class SpoonCatalogModel: ObservableObject {
    @Published private(set) var entries: [SpoonCatalogEntry] = []
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var lastError: String?

    enum LoadState { case idle, loading, loaded, failed }

    private let catokolasSource = CatokolasSource()
    private let officialSource  = HammerspoonOfficialSource()
    private let catalogCache    = CatalogCache()

    /// Live runner picked at startup. Nil when no `hs` CLI exists →
    /// orchestrator falls back to `NoOpLuaRunner` so Apply still
    /// persists.
    let bridge: HammerspoonBridge?

    /// Underlying runner the orchestrator (and the LuaLiteralEditor)
    /// uses. Never nil — degrades to `NoOpLuaRunner` when no bridge.
    /// Wrapped in a `BridgeRecorder` so the DiagnosticsView sees every
    /// `hs -c` call the app makes.
    let runner: any LuaRunner

    let recorder: BridgeRecorder

    /// Latest-first snapshot of bridge invocations. Bumped by the
    /// recorder's onRecord callback. Truncated to match the recorder's
    /// capacity.
    @Published var recentInvocations: [BridgeInvocation] = []

    let orchestrator: SpoonOrchestrator
    let installer:    SpoonInstaller
    let initLuaPatcher: InitLuaPatcher
    let updateChecker:  any UpdateChecker

    /// State machine for the init.lua require-line patch banner.
    @Published private(set) var initLuaPatchState: InitLuaPatchState = .checking

    enum InitLuaPatchState: Equatable {
        case checking
        case alreadyApplied
        case needsPatch(PatchPlan)
        case justApplied
        case dismissed
        case failed(String)
    }

    /// Bumps every time install/remove lands so views observing
    /// `isInstalled(_:)` re-render. SwiftUI's @Published machinery
    /// gives us the binding automatically.
    @Published private(set) var installSeq: Int = 0

    /// Latest upstream `InstalledRef` per Spoon name, captured by
    /// `checkForUpdates()`. The sidebar/detail compare this against
    /// `state.installedRef` to badge "update available".
    @Published private(set) var latestRefs: [String: InstalledRef] = [:]

    /// True while a checkForUpdates() pass is in flight; surfaced as a
    /// spinner on the sidebar refresh button.
    @Published private(set) var isCheckingForUpdates: Bool = false

    /// Active hotkey conflicts (cached snapshot). Recomputed via
    /// `recomputeHotkeyConflicts()` whenever state.json or the
    /// catalog changes.
    @Published private(set) var hotkeyConflicts: [HotkeyConflict] = []

    /// Other `.spoon` directories the app didn't install. Surfaced in
    /// the sidebar so the user knows what else is on disk.
    @Published private(set) var unmanagedSpoons: [UnmanagedSpoon] = []

    private let stateStore = StateStore()
    private let status: HammerspoonStatus

    private var hasLoaded = false

    init() {
        let status = HammerspoonEnvironment().snapshot()
        self.status = status
        let bridge = HammerspoonBridge(status: status)
        self.bridge = bridge

        // Wrap the actual runner in a recorder so every hs -c call
        // shows up in the diagnostics view. The bridge's no-op fallback
        // still gets recorded (with a failure result) — handy for
        // diagnosing "why isn't anything happening" when Hammerspoon
        // isn't running.
        let actualRunner: any LuaRunner = bridge ?? NoOpLuaRunner()
        let recorder = BridgeRecorder(wrapping: actualRunner, capacity: 50)
        self.recorder = recorder
        self.runner   = recorder

        // Snippet lives next to the user's init.lua.
        let snippetPath = status.configDir
            .appendingPathComponent("mac_spoons_tweaks.lua")

        // Providers read from the lock-guarded cache below; the model
        // updates it whenever a refresh lands a new catalog.
        let cache = catalogCache
        let entriesByName: @Sendable () -> [String: SpoonCatalogEntry] = {
            cache.read()
        }
        let catokolasRepo: RepoRef = catokolasSource.repoRef
        let reposByID: @Sendable () -> [String: RepoRef] = {
            // CatokolasSource → custom repo registration.
            // HammerspoonOfficialSource → built-in "default".
            return [
                "catokolas":               catokolasRepo,
                "hammerspoon-official":    .default,
            ]
        }

        self.orchestrator = SpoonOrchestrator(
            store:           stateStore,
            runner:          runner,
            snippetPath:     snippetPath,
            catalogProvider: entriesByName,
            reposProvider:   reposByID)

        // The installer drives SpoonInstall via the same runner the
        // orchestrator uses; bootstraps SpoonInstall.spoon on demand.
        let bootstrap = SpoonInstallBootstrap(status: status)
        self.installer = SpoonInstaller(
            bootstrap: bootstrap,
            runner:    runner,
            store:     stateStore)

        self.initLuaPatcher = InitLuaPatcher(status: status)

        // Composite update checker — git for our repo, zip-ETag for
        // upstream. Skip the git checker when git isn't available;
        // git strategies just don't resolve in that case.
        var checkers: [any UpdateChecker] = []
        if let git = try? SystemGitRunner() {
            checkers.append(GitUpdateChecker(runner: git))
        }
        checkers.append(ZipETagUpdateChecker())
        self.updateChecker = CompositeUpdateChecker(checkers)

        // Wire the recorder to publish each invocation through the
        // model so DiagnosticsView re-renders. Doing this AFTER all
        // stored properties are set lets the @Sendable closure safely
        // capture self.
        recorder.setObserver { [weak self] _ in
            guard let self = self else { return }
            let snapshot = recorder.recent()
            Task { @MainActor in
                self.recentInvocations = snapshot.reversed()  // newest-first
            }
        }
    }

    // MARK: - init.lua patcher

    /// Recompute the patch plan. Called on app launch (and after the
    /// user has externally edited init.lua, conceptually — for now,
    /// just on launch).
    func refreshInitLuaPatchState() {
        do {
            let plan = try initLuaPatcher.plan()
            initLuaPatchState = plan.alreadyApplied
                ? .alreadyApplied
                : .needsPatch(plan)
        } catch {
            initLuaPatchState = .failed(String(describing: error))
        }
    }

    func applyInitLuaPatch() async {
        guard case .needsPatch(let plan) = initLuaPatchState else { return }
        do {
            _ = try initLuaPatcher.apply(plan)
            initLuaPatchState = .justApplied
            // Auto-fade the success banner after a few seconds.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if initLuaPatchState == .justApplied {
                initLuaPatchState = .alreadyApplied
            }
        } catch {
            initLuaPatchState = .failed(String(describing: error))
        }
    }

    func dismissInitLuaBanner() {
        initLuaPatchState = .dismissed
    }

    // MARK: - Install / Remove

    /// Reads "is this Spoon installed?" off state.json. The view binds
    /// to `installSeq` so the answer is refreshed reactively.
    func isInstalled(_ entry: SpoonCatalogEntry) -> Bool {
        _ = installSeq                          // observation hook
        let state = (try? stateStore.load()) ?? AppState()
        return state.spoons[entry.name]?.installedRef != nil
    }

    /// Resolves a `RepoRef` for the given source.
    private func repoRef(for sourceID: String) -> RepoRef {
        switch sourceID {
        case catokolasSource.id: return catokolasSource.repoRef
        default:                 return .default
        }
    }

    /// Placeholder ref recorded at install time — the real one is filled
    /// in by `UpdateChecker` in a later phase. Until then "installed
    /// but unknown ref" still satisfies `isInstalled`.
    private func placeholderRef(for sourceID: String) -> InstalledRef {
        switch sourceID {
        case catokolasSource.id: return .gitCommit("installed")
        default:                 return .zipETag(value: "installed",
                                                 fetchedAt: Date())
        }
    }

    func install(_ entry: SpoonCatalogEntry) async throws {
        try await installer.install(
            entry:        entry,
            from:         repoRef(for: entry.sourceID),
            installedRef: placeholderRef(for: entry.sourceID))
        installSeq += 1
        recomputeHotkeyConflicts()
        scanUnmanagedSpoons()
        // Refine the placeholder with the actual upstream ref so the
        // first update check after install doesn't flap to "update
        // available" because of the placeholder.
        Task { await refineInstalledRef(for: entry) }
    }

    func remove(_ entry: SpoonCatalogEntry) async throws {
        try await installer.remove(name: entry.name)
        latestRefs[entry.name] = nil
        installSeq += 1
        recomputeHotkeyConflicts()
        scanUnmanagedSpoons()
    }

    // MARK: - Catalog drift

    /// Diff between an installed Spoon's captured schema and the
    /// current catalog entry. Empty when the install predates the
    /// snapshot feature or when nothing has changed.
    func catalogDrift(for entry: SpoonCatalogEntry) -> CatalogDrift {
        _ = installSeq                              // observation hook
        let state = (try? stateStore.load()) ?? AppState()
        return CatalogDriftDetector.detect(
            installedKeys: state.spoons[entry.name]?.installedSchemaKeys,
            currentEntry:  entry)
    }

    // MARK: - Unmanaged Spoons

    /// Re-scan `~/.hammerspoon/Spoons/` for Spoons the app didn't
    /// install. Excludes anything already represented in state.json
    /// (since adopting them would just be redundant).
    func scanUnmanagedSpoons() {
        let state = (try? stateStore.load()) ?? AppState()
        let managed = Set(state.spoons.keys)
        unmanagedSpoons = UnmanagedSpoonScanner.scan(
            spoonsDir: status.spoonsDir,
            excluding: managed)
    }

    // MARK: - Hotkey conflicts

    /// Re-evaluate the conflict snapshot from current state + catalog.
    /// Call after any operation that changes the effective bindings:
    /// install, remove, Apply.
    func recomputeHotkeyConflicts() {
        let state = (try? stateStore.load()) ?? AppState()
        let catalog = catalogCache.read()
        let merged = effectiveHotkeys(state: state, catalog: catalog)
        hotkeyConflicts = HotkeyConflictDetector.findConflicts(
            across: merged)
    }

    /// For each enabled-and-installed Spoon, project the bindings the
    /// user effectively has active: override if present, manifest
    /// default otherwise. Actions whose default is `nil` and have no
    /// override are skipped (they'd never fire).
    private func effectiveHotkeys(
        state: AppState,
        catalog: [String: SpoonCatalogEntry]
    ) -> [String: [String: HotkeyBinding]] {
        var out: [String: [String: HotkeyBinding]] = [:]
        for (name, spoon) in state.spoons {
            guard spoon.enabled,
                  spoon.installedRef != nil,
                  let entry = catalog[name]
            else { continue }
            var actions: [String: HotkeyBinding] = [:]
            for action in entry.hotkeys {
                if let override = spoon.hotkeys[action.action] {
                    actions[action.action] = override
                } else if let `default` = action.default {
                    actions[action.action] = `default`
                }
            }
            if !actions.isEmpty {
                out[name] = actions
            }
        }
        return out
    }

    // MARK: - Update detection

    /// Returns true iff we have both an installed ref and a latest ref
    /// from upstream, and they differ. The detail panel's Install
    /// button reads "Update" when this is true; the sidebar row shows
    /// a "↓" badge.
    func updateAvailable(for entry: SpoonCatalogEntry) -> Bool {
        _ = installSeq                                  // observation hook
        let state = (try? stateStore.load()) ?? AppState()
        return InstalledRef.updateAvailable(
            installed: state.spoons[entry.name]?.installedRef,
            latest:    latestRefs[entry.name])
    }

    /// Check every installed Spoon for an upstream update, in parallel.
    /// Best-effort: failures (no git, no network, etc.) don't surface
    /// as a global error — they just leave that Spoon's `latestRefs`
    /// entry untouched.
    func checkForUpdates() async {
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        // Snapshot the installed Spoons and their entry definitions.
        let state = (try? stateStore.load()) ?? AppState()
        let installed = state.spoons
            .filter { $0.value.installedRef != nil }
            .compactMap { (name, _) -> SpoonCatalogEntry? in
                catalogCache.read()[name]
            }

        await withTaskGroup(of: (String, InstalledRef?).self) { group in
            let checker = updateChecker
            let strategies = installed.map { ($0.name, strategy(for: $0)) }
            for (name, strategy) in strategies {
                guard let strategy = strategy else { continue }
                group.addTask {
                    let result = try? await checker.checkLatest(
                        strategy: strategy)
                    return (name, result)
                }
            }
            for await (name, latest) in group {
                if let latest = latest {
                    latestRefs[name] = latest
                }
            }
        }
    }

    /// Probe upstream for `entry` and persist the result as the new
    /// `installedRef`. Used right after install to replace the
    /// placeholder ref with the real one.
    private func refineInstalledRef(
        for entry: SpoonCatalogEntry
    ) async {
        guard let strategy = strategy(for: entry) else { return }
        let latest = try? await updateChecker.checkLatest(strategy: strategy)
        guard let latest = latest else { return }
        do {
            try stateStore.update { state in
                if state.spoons[entry.name] != nil {
                    state.spoons[entry.name]?.installedRef = latest
                }
            }
            latestRefs[entry.name] = latest
            installSeq += 1
        } catch {
            // Best effort — state stays with placeholder.
        }
    }

    /// Resolve a Spoon entry's `UpdateCheckStrategy` by routing through
    /// its `CatalogSource`. Returns `nil` for entries whose source
    /// isn't registered here.
    private func strategy(
        for entry: SpoonCatalogEntry
    ) -> UpdateCheckStrategy? {
        switch entry.sourceID {
        case catokolasSource.id:    return catokolasSource.updateCheckStrategy(for: entry)
        case officialSource.id:     return officialSource.updateCheckStrategy(for: entry)
        default:                    return nil
        }
    }

    // MARK: - Catalog refresh

    func refreshIfNeeded() async {
        if hasLoaded { return }
        await refresh()
    }

    func refresh() async {
        loadState = .loading
        lastError = nil
        do {
            // Fetch both sources in parallel.
            async let catokolas = catokolasSource.refresh()
            async let upstream  = officialSource.refresh()
            let ours      = try await catokolas
            let theirsRaw = (try? await upstream) ?? []

            // Apply our `overrides/` curation to upstream entries.
            let overrides = catokolasSource.overridesForUpstream
            let theirs = OverrideApplier.apply(
                entries: theirsRaw, overrides: overrides)

            let combined = (ours + theirs)
                .sorted {
                    $0.name.localizedCompare($1.name) == .orderedAscending
                }
            self.entries = combined
            catalogCache.update(Dictionary(
                uniqueKeysWithValues: combined.map { ($0.name, $0) }))
            loadState = .loaded
            hasLoaded = true
            recomputeHotkeyConflicts()
            scanUnmanagedSpoons()
            // Kick off an update check now that we know the catalog.
            // Best-effort — failures don't block the catalog loaded state.
            Task { await checkForUpdates() }
        } catch {
            loadState = .failed
            lastError = String(describing: error)
        }
    }
}
