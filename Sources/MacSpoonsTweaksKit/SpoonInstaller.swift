import Foundation

/// Orchestrates a Spoon install through `SpoonInstall.spoon` and tracks
/// the result in `StateStore`. Composes the three lower-level pieces:
///   * `SpoonInstallBootstrap` (one-time fetch of SpoonInstall.spoon)
///   * `LuaRunner` (drives the bridge)
///   * `StateStore` (persists installedRef + enabled state)
///
/// Does NOT compute precise install refs — the caller passes
/// `InstalledRef` explicitly. Phase 8 (`UpdateChecker`) will introduce
/// the git-SHA / zip-ETag probes that feed those values.
public final class SpoonInstaller: @unchecked Sendable {
    public let bootstrap: SpoonInstallBootstrap
    public let runner:    any LuaRunner
    public let store:     StateStore
    public let spoonsDir: URL

    public init(
        bootstrap: SpoonInstallBootstrap,
        runner:    any LuaRunner,
        store:     StateStore
    ) {
        self.bootstrap = bootstrap
        self.runner    = runner
        self.store     = store
        self.spoonsDir = bootstrap.spoonsDir
    }

    public enum InstallerError: Error, CustomStringConvertible {
        /// SpoonInstall returned anything other than the literal "ok"
        /// sentinel from the install script. Stdout carries whatever
        /// it actually said.
        case spoonInstallReportedFailure(stdout: String)
        /// `spoon.SpoonInstall:installSpoonFromRepo` completed but the
        /// expected `.spoon` directory didn't materialize. Indicates a
        /// SpoonInstall bug or a corrupted upstream artifact.
        case destinationMissingAfterInstall(URL)
        /// Destination is a symlink. SpoonInstall's `unzip -o` refuses
        /// to extract over a symlinked target dir; even if it didn't,
        /// silently overwriting an in-tree dev checkout would be the
        /// wrong default.
        case destinationIsSymlink(URL, target: URL)

        public var description: String {
            switch self {
            case .spoonInstallReportedFailure(let out):
                return "SpoonInstall failed: \(out)"
            case .destinationMissingAfterInstall(let url):
                return "Install reported success but \(url.path) is missing"
            case .destinationIsSymlink(let path, let target):
                return "\(path.lastPathComponent) is a symlink to "
                    + "\(target.path). Remove the symlink first if you "
                    + "want a managed copy installed."
            }
        }
    }

    /// Install (or update — same SpoonInstall API) a Spoon and record
    /// the new state. Idempotent for the same `installedRef`: SpoonInstall
    /// will overwrite the existing dir, and the StateStore mutation is
    /// idempotent on equal values.
    ///
    /// Existing config / hotkeys / enabled in state.json are PRESERVED —
    /// the user's prior choices survive a reinstall or update.
    public func install(
        entry: SpoonCatalogEntry,
        from repo: RepoRef,
        installedRef: InstalledRef
    ) async throws {
        let destination = spoonsDir
            .appendingPathComponent(entry.name + ".spoon")
        if let symlinkTarget = symlinkTarget(of: destination) {
            throw InstallerError.destinationIsSymlink(
                destination, target: symlinkTarget)
        }
        try await bootstrap.ensureInstalled()
        let script = SpoonInstallScript.install(name: entry.name, repo: repo)
        let result = try await runner.runLua(script, timeout: 30)
        // hs.loadSpoon / updateRepo print `-- Loading extension: …` log
        // lines to stdout BEFORE the script's return value lands, so
        // strict equality against `"ok"` rejects every real install. The
        // sentinel is the last non-empty line — match against that.
        let lastLine = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        guard lastLine == "ok" else {
            throw InstallerError.spoonInstallReportedFailure(stdout: result)
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw InstallerError.destinationMissingAfterInstall(destination)
        }
        try store.update { state in
            // Preserve any existing user-supplied config/hotkeys/enabled.
            let existing = state.spoons[entry.name]
            state.spoons[entry.name] = SpoonState(
                sourceID:           entry.sourceID,
                enabled:            existing?.enabled ?? false,
                installedRef:       installedRef,
                installedSchemaKeys: CatalogDriftDetector
                    .snapshotKeys(from: entry),
                config:             existing?.config  ?? [:],
                hotkeys:            existing?.hotkeys ?? [:])
        }
    }

    /// Returns the resolved target if `url` is a symlink (whether or
    /// not the target exists); nil otherwise. Used to detect dev-style
    /// symlinks in `~/.hammerspoon/Spoons/` before SpoonInstall's
    /// `unzip -o` would fail with "cannot enter ... Permission denied".
    private func symlinkTarget(of url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink == true else { return nil }
        let dest = try? FileManager.default
            .destinationOfSymbolicLink(atPath: url.path)
        guard let dest = dest else { return url.resolvingSymlinksInPath() }
        if dest.hasPrefix("/") {
            return URL(fileURLWithPath: dest)
        }
        return url.deletingLastPathComponent()
            .appendingPathComponent(dest)
            .standardizedFileURL
    }

    /// Stop, unload, delete the Spoon, and clear it from `state.spoons`.
    /// Safe to call when the Spoon is partially installed or already
    /// gone — every step is best-effort and the final state is "Spoon
    /// is absent".
    public func remove(name: String) async throws {
        let destination = spoonsDir.appendingPathComponent(name + ".spoon")

        // Stop + unload via Lua. Run this first so the Spoon isn't
        // actively holding event taps when we delete its source on disk.
        _ = try? await runner.runLua(
            SpoonInstallScript.unload(name: name), timeout: 5)

        // Remove the directory if present. Errors here are non-fatal —
        // missing dir is the goal; permission errors should be surfaced
        // but rare.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        try store.update { state in
            state.spoons[name] = nil
        }
    }
}

// MARK: - CatalogSource RepoRef plumbing

public extension CatalogSource {
    /// Each `CatalogSource` exposes how to register itself with
    /// SpoonInstall. Default implementation returns `.default`, which is
    /// correct for the official `Hammerspoon/Spoons` repo. Custom
    /// sources (like `CatokolasSource`) override this to return a
    /// `.custom(...)` describing their git remote.
    var repoRef: RepoRef { .default }
}

public extension CatokolasSource {
    var repoRef: RepoRef {
        .custom(
            id:     id,
            url:    "https://github.com/catokolas/HS_SpoonsContrib",
            branch: "main",
            desc:   "Cato Kolås's contributed Spoons")
    }
}
