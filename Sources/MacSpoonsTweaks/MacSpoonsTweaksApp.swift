import SwiftUI
import AppKit
import MacSpoonsTweaksKit

@main
struct MacSpoonsTweaksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var catalog = SpoonCatalogModel()

    var body: some Scene {
        // Single-window scene (Window, not WindowGroup) so the menu
        // bar's `openWindow(id:)` focuses the existing window instead
        // of spawning a duplicate.
        Window("Mac Spoons Tweaks", id: "main") {
            ContentView()
                .environmentObject(catalog)
                .luaRunner(catalog.runner)
                // Apply the user's font-size preset HERE at the App
                // scene level AND force a full ContentView rebuild on
                // change via `.id`. On macOS, SwiftUI's
                // `.dynamicTypeSize` environment only takes effect on
                // first render of a view; mutating it reactively
                // doesn't re-render already-rendered text. The `.id`
                // tied to the preset side-steps that by replacing the
                // ContentView instance whenever the preset changes.
                // Custom multiplier the `.scaledFont(_:weight:)`
                // modifier reads. Reliable across macOS versions
                // (Dynamic Type honouring varies in 26+).
                .environment(\.appFontScale,
                             catalog.fontSize.sizeScale)
                // Keep `.dynamicTypeSize` set too — it covers some
                // system-rendered widgets (Picker labels, menu items)
                // that don't go through `.scaledFont`.
                .environment(\.dynamicTypeSize,
                             catalog.fontSize.dynamicTypeSize)
                .task { await catalog.bootstrapSpoonInstall() }
                .task { await catalog.refreshIfNeeded() }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(catalog)
        } label: {
            // Filled variant + explicit weight/size for a heavier
            // presence in the menu bar. The system caps the rendered
            // height, but bold + filled reads stronger than the
            // default thin outline.
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 18, weight: .bold))
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Mac Spoons Tweaks") {
                    AboutPanel.show(fontSize: catalog.fontSize)
                }
            }
        }
    }
}

/// Lock-guarded snapshot of the catalog so the orchestrator's
/// `@Sendable` provider closures can read it from any actor.
/// Lock-guarded `[String: RepoRef]` snapshot — same pattern as
/// `CatalogCache`, used by the orchestrator's `reposProvider` closure
/// so user-added catalogs become installable as soon as they're added.
private final class ReposCache: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: RepoRef] = [:]

    func update(_ new: [String: RepoRef]) {
        lock.lock(); defer { lock.unlock() }
        byID = new
    }

    func read() -> [String: RepoRef] {
        lock.lock(); defer { lock.unlock() }
        return byID
    }
}

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
    /// User-added catalogs hydrated from `state.customCatalogs`. Mutated
    /// by `addCustomCatalog` / `removeCustomCatalog` / `setCatalogEnabled`;
    /// `refresh()` fans out across every enabled entry.
    @Published private(set) var userSources: [UserCatalogSource] = []
    private let catalogCache    = CatalogCache()
    private let reposCache      = ReposCache()

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
    let installer:        SpoonInstaller
    let moduleInstaller:  NativeModuleInstaller
    let initLuaPatcher: InitLuaPatcher
    let updateChecker:     any UpdateChecker
    let changelogProvider: any SpoonChangelogProvider

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

    /// User-selected font-size preset, hydrated from state.json on
    /// launch and persisted on every change. The window root, all
    /// sheets, the MenuBarExtra content, and the About panel inject
    /// `fontSize.dynamicTypeSize` into the SwiftUI environment so
    /// every Text/Label scales together.
    @Published private(set) var fontSize: FontSizePreset = .xLarge

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
        // Seed the reposCache with the built-ins; user-added catalogs
        // are merged in via `rebuildReposCache()` after hydration.
        reposCache.update([
            "catokolas":            catokolasRepo,
            "hammerspoon-official": .default,
        ])
        let repos = reposCache
        let reposByID: @Sendable () -> [String: RepoRef] = {
            repos.read()
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

        self.moduleInstaller = NativeModuleInstaller(
            status: status, store: stateStore)

        self.initLuaPatcher = InitLuaPatcher(status: status)

        // Composite update checker — git for our repo, zip-ETag for
        // upstream. Skip the git checker when git isn't available;
        // git strategies just don't resolve in that case.
        var checkers: [any UpdateChecker] = []
        var changelogProviders: [any SpoonChangelogProvider] = []
        if let git = try? SystemGitRunner() {
            checkers.append(GitUpdateChecker(runner: git))
            // Same git binary feeds the change-preview provider for
            // catokolas + user catalogs.
            changelogProviders.append(
                GitSpoonChangelogProvider(runner: git))
        }
        checkers.append(ZipETagUpdateChecker())
        // Upstream change preview hits GitHub's Commits API. Best
        // effort — degrades to "no preview" if there's no network.
        changelogProviders.append(UpstreamCommitsAPIChangelogProvider())
        self.updateChecker = CompositeUpdateChecker(checkers)
        self.changelogProvider = CompositeSpoonChangelogProvider(
            changelogProviders)

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

        // Hydrate user catalogs + the font-size preset from state.json
        // so they survive a relaunch. `rebuildReposCache` keeps the
        // orchestrator's reposProvider consistent with the user-added
        // set.
        hydrateUserSourcesFromState()
        rebuildReposCache()
        let bootState = (try? stateStore.load()) ?? AppState()
        self.fontSize = bootState.fontSize
    }

    // MARK: - Custom catalogs

    private func hydrateUserSourcesFromState() {
        let state = (try? stateStore.load()) ?? AppState()
        userSources = state.customCatalogs
            .filter(\.enabled)
            .map { UserCatalogSource(config: $0) }
    }

    private func rebuildReposCache() {
        let catokolasRepo = catokolasSource.repoRef
        var byID: [String: RepoRef] = [
            "catokolas":            catokolasRepo,
            "hammerspoon-official": .default,
        ]
        for src in userSources {
            byID[src.id] = src.repoRef
        }
        reposCache.update(byID)
    }

    /// Add a user catalog, persist, and refresh.
    /// Returns true on success; false if a probe of the spoons.json
    /// fails (the caller — the Manage catalogs sheet — surfaces the
    /// reason via its own form state).
    func addCustomCatalog(
        owner: String, repo: String,
        branch: String = "main", description: String? = nil
    ) async -> Bool {
        let config = CustomCatalogConfig(
            owner: owner, repo: repo,
            branch: branch, description: description, enabled: true)
        do {
            // Probe the catalog URL before persisting. Any non-2xx or
            // network error means we don't add the row.
            let probe = UserCatalogSource(config: config)
            _ = try await probe.refresh()
        } catch {
            return false
        }
        do {
            try stateStore.update { state in
                // Idempotent: replace any prior entry for the same id.
                state.customCatalogs.removeAll { $0.id == config.id }
                state.customCatalogs.append(config)
            }
        } catch {
            return false
        }
        hydrateUserSourcesFromState()
        rebuildReposCache()
        await refresh()
        return true
    }

    func removeCustomCatalog(id: String) async {
        do {
            try stateStore.update { state in
                state.customCatalogs.removeAll { $0.id == id }
            }
        } catch { return }
        hydrateUserSourcesFromState()
        rebuildReposCache()
        await refresh()
    }

    func setCatalogEnabled(id: String, enabled: Bool) async {
        do {
            try stateStore.update { state in
                if let i = state.customCatalogs.firstIndex(where: { $0.id == id }) {
                    state.customCatalogs[i].enabled = enabled
                }
            }
        } catch { return }
        hydrateUserSourcesFromState()
        rebuildReposCache()
        await refresh()
    }

    /// SwiftUI-friendly snapshot for the Manage catalogs sheet.
    func customCatalogConfigs() -> [CustomCatalogConfig] {
        let state = (try? stateStore.load()) ?? AppState()
        return state.customCatalogs
    }

    // MARK: - Font size

    /// True iff the next-larger preset is reachable.
    var canIncreaseFontSize: Bool {
        return FontSizePreset.allCases.last != fontSize
    }

    /// True iff a smaller preset is reachable.
    var canDecreaseFontSize: Bool {
        return FontSizePreset.allCases.first != fontSize
    }

    /// Step one stop larger and persist. No-op at the top of the ladder.
    func increaseFontSize() {
        let all = FontSizePreset.allCases
        guard let i = all.firstIndex(of: fontSize), i + 1 < all.count
        else { return }
        applyFontSize(all[i + 1])
    }

    /// Step one stop smaller and persist. No-op at the bottom.
    func decreaseFontSize() {
        let all = FontSizePreset.allCases
        guard let i = all.firstIndex(of: fontSize), i > 0
        else { return }
        applyFontSize(all[i - 1])
    }

    private func applyFontSize(_ next: FontSizePreset) {
        // Persist first so a write failure doesn't leave the UI lying.
        do {
            try stateStore.update { $0.fontSize = next }
        } catch {
            return
        }
        fontSize = next
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

    /// Resolves a `RepoRef` for the given source. User catalogs share
    /// the catokolas-style `.custom` shape and bypass the default.
    private func repoRef(for sourceID: String) -> RepoRef {
        switch sourceID {
        case catokolasSource.id: return catokolasSource.repoRef
        default:
            if let src = userSources.first(where: { $0.id == sourceID }) {
                return src.repoRef
            }
            return .default
        }
    }

    /// Placeholder ref recorded at install time — the real one is filled
    /// in by `UpdateChecker` in a later phase. Until then "installed
    /// but unknown ref" still satisfies `isInstalled`. User catalogs
    /// share the catokolas placeholder shape (git-commit).
    private func placeholderRef(for sourceID: String) -> InstalledRef {
        switch sourceID {
        case catokolasSource.id: return .gitCommit("installed")
        default:
            if userSources.contains(where: { $0.id == sourceID }) {
                return .gitCommit("installed")
            }
            return .zipETag(value: "installed",
                            fetchedAt: Date())
        }
    }

    func install(_ entry: SpoonCatalogEntry) async throws {
        try await installer.install(
            entry:        entry,
            from:         repoRef(for: entry.sourceID),
            installedRef: placeholderRef(for: entry.sourceID))

        // Auto-activate so the Spoon is usable immediately: flip
        // enabled, write the snippet, push live. Fresh installs get
        // the manifest's default hotkeys; reinstalls preserve whatever
        // overrides the user already set. Best-effort — a live-apply
        // failure (no Hammerspoon running, missing permissions) does
        // not unwind the on-disk install.
        let seed = orchestrator.seedState(for: entry.name)
        let hotkeys = seed.hotkeys.isEmpty
            ? HotkeyAction.defaults(from: entry.hotkeys)
            : seed.hotkeys
        _ = try? await orchestrator.apply(
            entry:           entry,
            values:          seed.config,
            hotkeyOverrides: hotkeys)

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

    // MARK: - Optional native modules

    /// Latest known release tag per module name. Refreshed lazily when
    /// the detail view appears via `refreshModuleLatestTag(_:)`. Empty
    /// when we haven't probed yet or the API call failed.
    @Published private(set) var moduleLatestTags: [String: String] = [:]

    /// Aggregated status the detail view binds to. Computed cheaply
    /// (FS check + dictionary lookup); SwiftUI re-evaluates whenever
    /// `installSeq` or `moduleLatestTags` changes.
    func moduleStatus(_ m: OptionalModule) -> NativeModuleStatus {
        _ = installSeq
        let state = (try? stateStore.load()) ?? AppState()
        let installed = moduleInstaller.isInstalled(m)
        let installedTag = state.nativeModules[m.name]?.installedVersion
        let latest = moduleLatestTags[m.name]
        return NativeModuleStatus(
            installed:        installed,
            installedTag:     installed ? installedTag : nil,
            latestTag:        latest)
    }

    /// Best-effort GitHub HEAD probe to populate `moduleLatestTags`.
    /// Swallows errors — the UI just won't show "Update available" if
    /// the network is down.
    func refreshModuleLatestTag(_ m: OptionalModule) async {
        if let tag = await moduleInstaller.latestTag(for: m) {
            moduleLatestTags[m.name] = tag
        }
    }

    func installModule(_ m: OptionalModule) async throws {
        _ = try await moduleInstaller.install(module: m)
        installSeq += 1
    }

    func removeModule(_ m: OptionalModule) throws {
        try moduleInstaller.remove(module: m)
        installSeq += 1
    }

    // MARK: - Pause / Resume

    /// Reads `paused` off state.json. Bound to `installSeq` so SwiftUI
    /// observers re-render whenever pause/install/remove changes land.
    func isPaused(_ entry: SpoonCatalogEntry) -> Bool {
        _ = installSeq
        let state = (try? stateStore.load()) ?? AppState()
        return state.spoons[entry.name]?.paused ?? false
    }

    /// Toggle pause and refresh observers. Returns the orchestrator's
    /// `ApplyResult` so callers can surface live errors.
    @discardableResult
    func setPaused(
        _ entry: SpoonCatalogEntry, _ paused: Bool
    ) async throws -> SpoonOrchestrator.ApplyResult {
        let result = try await orchestrator.setPaused(
            entry: entry, paused: paused)
        installSeq += 1
        recomputeHotkeyConflicts()
        return result
    }

    /// Spoons the user can pause: installed, enabled, with both `:start`
    /// and `:stop` methods. Sorted by name for stable menu order.
    func pausableEnabledSpoons() -> [SpoonCatalogEntry] {
        _ = installSeq
        let state = (try? stateStore.load()) ?? AppState()
        return entries
            .filter { entry in
                guard entry.lifecycle.hasStart, entry.lifecycle.hasStop
                else { return false }
                guard let s = state.spoons[entry.name] else { return false }
                return s.enabled && s.installedRef != nil
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: - Active toggle (unified)

    /// "Is this Spoon doing what I want?" — wraps the enabled/paused
    /// fields so the UI doesn't have to branch on lifecycle. True means
    /// either (a) the Spoon has start/stop and isn't paused, or
    /// (b) the Spoon has no start/stop but is enabled (in the snippet).
    func isActive(_ entry: SpoonCatalogEntry) -> Bool {
        _ = installSeq
        let state = (try? stateStore.load()) ?? AppState()
        guard let s = state.spoons[entry.name] else { return false }
        if entry.lifecycle.hasStart && entry.lifecycle.hasStop {
            return s.enabled && !s.paused
        }
        return s.enabled
    }

    /// Flip Active. For pausable Spoons toggles `paused`; for the rest
    /// (AClock-style) toggles `enabled`. Activating always ensures
    /// `enabled=true && paused=false` so the snippet has a fresh state.
    @discardableResult
    func setActive(
        _ entry: SpoonCatalogEntry, _ active: Bool
    ) async throws -> SpoonOrchestrator.ApplyResult {
        let result: SpoonOrchestrator.ApplyResult
        if entry.lifecycle.hasStart && entry.lifecycle.hasStop {
            result = try await orchestrator.setPaused(
                entry: entry, paused: !active)
        } else {
            result = try await orchestrator.setEnabled(
                entry: entry, enabled: active)
        }
        installSeq += 1
        recomputeHotkeyConflicts()
        return result
    }

    /// Every installed Spoon — surfaced in the menu submenu so the user
    /// can toggle Active for the non-pausable ones too. Sorted by name.
    func toggleableInstalledSpoons() -> [SpoonCatalogEntry] {
        _ = installSeq
        let state = (try? stateStore.load()) ?? AppState()
        return entries
            .filter { entry in
                guard let s = state.spoons[entry.name] else { return false }
                return s.installedRef != nil
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
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

    /// View-friendly snapshot of an entry's installed ref. The sheet
    /// uses this to render "From <short> → <short>".
    func installedRefSnapshot(
        for entry: SpoonCatalogEntry
    ) -> InstalledRef? {
        _ = installSeq
        let state = (try? stateStore.load()) ?? AppState()
        return state.spoons[entry.name]?.installedRef
    }

    /// Build the "what's changed?" preview for a Spoon. Looks up its
    /// installed and latest refs, routes through the strategy, and
    /// asks the composite provider. Surface errors as-is — the sheet
    /// is the only consumer.
    func changelog(
        for entry: SpoonCatalogEntry
    ) async throws -> SpoonChangelog {
        guard let strategy = strategy(for: entry) else {
            throw SpoonChangelogError.unsupportedStrategy
        }
        let state = (try? stateStore.load()) ?? AppState()
        let installed = state.spoons[entry.name]?.installedRef
        let latest    = latestRefs[entry.name]
        return try await changelogProvider.changelog(
            for: entry, strategy: strategy,
            installed: installed, latest: latest)
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
        default:
            if let src = userSources.first(where: { $0.id == entry.sourceID }) {
                return src.updateCheckStrategy(for: entry)
            }
            return nil
        }
    }

    // MARK: - Catalog refresh

    func refreshIfNeeded() async {
        if hasLoaded { return }
        await refresh()
    }

    /// Idempotent — returns immediately if SpoonInstall.spoon is already
    /// in `~/.hammerspoon/Spoons/`. Otherwise fetches it. Best-effort:
    /// network failures are swallowed; the snippet's defensive check
    /// surfaces a clear error to the user at next Hammerspoon load.
    func bootstrapSpoonInstall() async {
        try? await installer.bootstrap.ensureInstalled()
    }

    func refresh() async {
        loadState = .loading
        lastError = nil
        do {
            // Fetch built-in sources in parallel.
            async let catokolas = catokolasSource.refresh()
            async let upstream  = officialSource.refresh()
            let ours      = try await catokolas
            let theirsRaw = (try? await upstream) ?? []

            // User catalogs are best-effort: a single bad catalog must
            // not poison the whole sidebar. Fetch them in parallel and
            // swallow individual errors.
            let snapshot = userSources
            var userEntries: [[SpoonCatalogEntry]] = []
            await withTaskGroup(of: [SpoonCatalogEntry].self) { group in
                for source in snapshot {
                    group.addTask {
                        return (try? await source.refresh()) ?? []
                    }
                }
                for await result in group {
                    userEntries.append(result)
                }
            }

            // Apply our `overrides/` curation to upstream entries.
            let overrides = catokolasSource.overridesForUpstream
            let theirs = OverrideApplier.apply(
                entries: theirsRaw, overrides: overrides)

            // Catokolas wins on name collisions; then user catalogs in
            // user-added order; upstream loses to all of the above.
            // We publish a couple of Spoons (e.g. MoveSpaces) that also
            // exist upstream, and the catalog dictionary later keys by
            // name.
            var seen = Set(ours.map { $0.name })
            var combined: [SpoonCatalogEntry] = ours
            for batch in userEntries {
                for entry in batch where !seen.contains(entry.name) {
                    combined.append(entry)
                    seen.insert(entry.name)
                }
            }
            for entry in theirs where !seen.contains(entry.name) {
                combined.append(entry)
                seen.insert(entry.name)
            }
            combined.sort {
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
