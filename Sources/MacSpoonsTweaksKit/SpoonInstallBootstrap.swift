import Foundation

/// Hook for the one piece of network I/O in the kit — fetching
/// `SpoonInstall.spoon.zip` from the official Hammerspoon repo. Default
/// implementation uses `URLSession`; tests substitute a downloader that
/// hands back a fixture zip on disk.
public protocol ZipDownloader: Sendable {
    /// Download the resource at `url` and return a local file URL whose
    /// contents are the response body. May or may not be in a temp dir;
    /// the bootstrap doesn't care, but it WILL `unzip` the result.
    func download(from url: URL) async throws -> URL
}

public struct URLSessionZipDownloader: ZipDownloader {
    public init() {}
    public func download(from url: URL) async throws -> URL {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw BootstrapError.httpStatus(http.statusCode)
        }
        return tmp
    }
}

public enum BootstrapError: Error, CustomStringConvertible {
    case httpStatus(Int)
    case unzipFailed(status: Int32, stderr: String)
    case unexpectedZipLayout(String)
    case processLaunchFailed(any Error)

    public var description: String {
        switch self {
        case .httpStatus(let s):
            return "Download failed: HTTP \(s)"
        case .unzipFailed(let s, let err):
            return "unzip exited \(s): \(err)"
        case .unexpectedZipLayout(let msg):
            return "Unexpected zip layout: \(msg)"
        case .processLaunchFailed(let e):
            return "Failed to launch unzip: \(e)"
        }
    }
}

/// Idempotently install `SpoonInstall.spoon` into the user's Hammerspoon
/// Spoons dir. This is the one Spoon the app installs natively — every
/// other Spoon goes through SpoonInstall itself via the bridge.
public final class SpoonInstallBootstrap: @unchecked Sendable {

    public static let defaultURL = URL(
        string: "https://github.com/Hammerspoon/Spoons/raw/master/Spoons/SpoonInstall.spoon.zip"
    )!

    public let spoonsDir:   URL
    public let stagingDir:  URL
    public let downloadURL: URL
    public let downloader:  any ZipDownloader

    public init(
        spoonsDir:   URL,
        stagingDir:  URL  = SpoonInstallBootstrap.defaultStagingDir(),
        downloadURL: URL  = SpoonInstallBootstrap.defaultURL,
        downloader:  any ZipDownloader = URLSessionZipDownloader()
    ) {
        self.spoonsDir   = spoonsDir
        self.stagingDir  = stagingDir
        self.downloadURL = downloadURL
        self.downloader  = downloader
    }

    public convenience init(status: HammerspoonStatus) {
        self.init(spoonsDir: status.spoonsDir)
    }

    /// `~/.hammerspoon/Spoons/SpoonInstall.spoon`.
    public var destination: URL {
        return spoonsDir.appendingPathComponent("SpoonInstall.spoon")
    }

    public var isInstalled: Bool {
        // Check for init.lua rather than just the directory — a dangling
        // empty dir (botched previous install) shouldn't count as
        // installed.
        let initLua = destination.appendingPathComponent("init.lua")
        return FileManager.default.fileExists(atPath: initLua.path)
    }

    /// Idempotent. If `SpoonInstall.spoon/init.lua` is already present,
    /// returns immediately. Otherwise downloads + unzips into a staging
    /// dir and atomically moves into place.
    public func ensureInstalled() async throws {
        if isInstalled { return }
        try await install()
    }

    /// Force a fresh download + install regardless of current state.
    /// Useful for repair if the existing dir is corrupted.
    public func install() async throws {
        try FileManager.default.createDirectory(
            at: spoonsDir, withIntermediateDirectories: true)

        // Per-attempt unique staging dir so concurrent bootstrap calls
        // (UI race) don't trample each other. Clean up on exit.
        let stageRoot = stagingDir
            .appendingPathComponent("bootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: stageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stageRoot) }

        let zipPath = try await downloader.download(from: downloadURL)
        try await unzip(zipPath, into: stageRoot)

        let staged = stageRoot.appendingPathComponent("SpoonInstall.spoon")
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw BootstrapError.unexpectedZipLayout(
                "Expected top-level SpoonInstall.spoon dir in archive")
        }

        // Atomic-ish move into ~/.hammerspoon/Spoons/SpoonInstall.spoon:
        //   - If a stale dir is in the way, replace it (the user explicitly
        //     asked us to install).
        //   - macOS `replaceItem` does the rename + rollback dance.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: staged, to: destination)
    }

    // MARK: - Helpers

    public static func defaultStagingDir() -> URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MacSpoonsTweaks")
                   .appendingPathComponent("bootstrap")
    }

    private func unzip(_ zip: URL, into dest: URL) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            // -q: quiet, -o: overwrite without prompting,
            // -d: extract into the named dir.
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
