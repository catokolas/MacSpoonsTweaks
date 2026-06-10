import Foundation

/// Installs / removes / updates companion native Hammerspoon modules
/// (the `hs._ckol.*` family) declared via `OptionalModule` on a
/// Spoon's manifest. Mirrors `SpoonInstallBootstrap`'s download-then-
/// unzip flow but:
///   * targets `~/.hammerspoon/` (release zips ship the
///     `hs/_ckol/<name>/…` prefix internally),
///   * resolves the download URL via the GitHub Releases API (the
///     repo doesn't expose a stable `latest.zip`),
///   * persists the installed release tag into
///     `AppState.nativeModules` so the UI can flag updates.
public final class NativeModuleInstaller: @unchecked Sendable {

    public let hammerspoonRoot: URL
    public let stagingDir:      URL
    public let releases:        any GitHubReleasesClient
    public let downloader:      any ZipDownloader
    public let store:           StateStore
    public let clock:           @Sendable () -> Date

    public init(
        hammerspoonRoot: URL,
        stagingDir:      URL = NativeModuleInstaller.defaultStagingDir(),
        releases:        any GitHubReleasesClient = URLSessionGitHubReleasesClient(),
        downloader:      any ZipDownloader = URLSessionZipDownloader(),
        store:           StateStore,
        clock:           @escaping @Sendable () -> Date = { Date() }
    ) {
        self.hammerspoonRoot = hammerspoonRoot
        self.stagingDir      = stagingDir
        self.releases        = releases
        self.downloader      = downloader
        self.store           = store
        self.clock           = clock
    }

    public convenience init(status: HammerspoonStatus, store: StateStore) {
        self.init(hammerspoonRoot: status.configDir, store: store)
    }

    public enum InstallerError: Error, CustomStringConvertible {
        case noMatchingAsset(repo: String, pattern: String,
                             tried: [String])
        case installSubdirMissingAfterUnzip(URL)

        public var description: String {
            switch self {
            case .noMatchingAsset(let repo, let pattern, let tried):
                return "Release for \(repo) had no asset matching "
                    + "'\(pattern)'. Got: \(tried.joined(separator: ", "))"
            case .installSubdirMissingAfterUnzip(let url):
                return "Unzipped but \(url.path) is missing"
            }
        }
    }

    public struct InstalledNativeModule: Sendable, Equatable {
        public let module:  OptionalModule
        public let tagName: String
    }

    // MARK: - Public API

    /// Returns the resolved install URL (`~/.hammerspoon/<installSubdir>`)
    /// for `module`.
    public func destination(for module: OptionalModule) -> URL {
        return hammerspoonRoot
            .appendingPathComponent(module.installSubdir)
    }

    /// True iff `destination(for:)` exists. We trust the FS rather than
    /// just state.json so a manual `rm -rf` shows up correctly.
    public func isInstalled(_ module: OptionalModule) -> Bool {
        return FileManager.default.fileExists(
            atPath: destination(for: module).path)
    }

    /// Fetch the latest release tag for `module.repo`. Returns nil on
    /// network failure — callers treat that as "don't know" rather than
    /// fail.
    public func latestTag(for module: OptionalModule) async -> String? {
        return try? await releases.latestRelease(repo: module.repo).tagName
    }

    /// Idempotent — replaces any existing install. Persists the
    /// resulting tag to `AppState.nativeModules[module.name]`.
    @discardableResult
    public func install(
        module: OptionalModule
    ) async throws -> InstalledNativeModule {
        let release = try await releases.latestRelease(repo: module.repo)
        guard let asset = release.assets.first(where: {
            matchAssetPattern(module.assetPattern, against: $0.name)
        }) else {
            throw InstallerError.noMatchingAsset(
                repo:    module.repo,
                pattern: module.assetPattern,
                tried:   release.assets.map { $0.name })
        }

        try FileManager.default.createDirectory(
            at: hammerspoonRoot, withIntermediateDirectories: true)
        let stageRoot = stagingDir
            .appendingPathComponent("module-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: stageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stageRoot) }

        let zipPath = try await downloader.download(
            from: asset.browserDownloadURL)
        try await unzip(zipPath, into: stageRoot)

        // The release zips embed the `hs/_ckol/<name>/…` prefix. Find
        // it in the stage and move it into place.
        let stagedSubtree = stageRoot
            .appendingPathComponent(module.installSubdir)
        guard FileManager.default.fileExists(atPath: stagedSubtree.path) else {
            throw InstallerError.installSubdirMissingAfterUnzip(stagedSubtree)
        }

        let target = destination(for: module)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: stagedSubtree, to: target)

        try store.update { state in
            state.nativeModules[module.name] = NativeModuleState(
                installedVersion: release.tagName,
                installedAt:      clock())
        }
        return InstalledNativeModule(module: module, tagName: release.tagName)
    }

    /// Delete the install dir and clear `AppState.nativeModules[name]`.
    /// Idempotent — missing dir / state is treated as success.
    public func remove(module: OptionalModule) throws {
        let target = destination(for: module)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try store.update { state in
            state.nativeModules[module.name] = nil
        }
    }

    // MARK: - Helpers

    public static func defaultStagingDir() -> URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MacSpoonsTweaks")
                   .appendingPathComponent("native-modules")
    }

    /// Duplicated from `SpoonInstallBootstrap` rather than refactored
    /// into a shared utility — keeping that file untouched avoids
    /// regression risk on the already-tested SpoonInstall flow.
    private func unzip(_ zip: URL, into dest: URL) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", "-o", zip.path, "-d", dest.path]
            let stderr = Pipe()
            process.standardError = stderr

            let lock = NSLock()
            var resumed = false
            func resumeOnce(_ result: Result<Void, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success:        continuation.resume(returning: ())
                case .failure(let e): continuation.resume(throwing: e)
                }
            }

            process.terminationHandler = { p in
                let errData = (try? stderr.fileHandleForReading.readToEnd())
                                ?? Data()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                if p.terminationStatus != 0 {
                    resumeOnce(.failure(BootstrapError.unzipFailed(
                        status: p.terminationStatus, stderr: errStr)))
                } else {
                    resumeOnce(.success(()))
                }
            }

            do {
                try process.run()
            } catch {
                resumeOnce(.failure(BootstrapError.processLaunchFailed(error)))
            }
        }
    }
}
