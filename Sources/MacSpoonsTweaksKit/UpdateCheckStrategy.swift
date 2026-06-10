import Foundation

/// How to determine whether an upstream update is available for a given
/// Spoon. The `UpdateChecker` switches on this to pick the right probe.
///
/// `gitCommitForSubdir`: the source is our HS_SpoonsContrib (or any
/// SpoonInstall-compatible git repo). A shallow clone in the app cache
/// is fetched, then `git log -1 --pretty=%H origin/<ref> -- <subdir>`
/// gives the latest commit touching the Spoon's source.
///
/// `zipETag`: the source is `Hammerspoon/Spoons`, distributed as zip
/// files. `HEAD <url>` returns the upstream ETag (or Last-Modified);
/// the installer stored this when it last downloaded. A change implies
/// a new artifact.
public enum UpdateCheckStrategy: Sendable, Equatable {
    case gitCommitForSubdir(repo: URL, subdir: String, ref: String)
    case zipETag(URL)
}

// MARK: - CatalogSource hook

public extension CatalogSource {
    /// Default strategy for any source we haven't hand-wired: assume
    /// a zip-distributed Spoon and use ETag. Concrete sources should
    /// override.
    func updateCheckStrategy(for entry: SpoonCatalogEntry) -> UpdateCheckStrategy {
        // Stub URL — the default zip-source URL pattern lands when
        // HammerspoonOfficialSource ships (phase 10).
        let url = URL(string: "https://example.invalid/" + entry.name + ".spoon.zip")!
        return .zipETag(url)
    }
}

public extension CatokolasSource {
    func updateCheckStrategy(for entry: SpoonCatalogEntry) -> UpdateCheckStrategy {
        return .gitCommitForSubdir(
            repo:   URL(string: "https://github.com/catokolas/HS_SpoonsContrib")!,
            subdir: "\(entry.name).spoon",
            ref:    "main")
    }
}

// MARK: - State comparison helper

public extension InstalledRef {
    /// Caller-friendly "should we show 'Update available'?" predicate.
    /// Both args nil → false; either nil → false (can't compare); equal
    /// identity → false; different identity → true.
    ///
    /// `zipETag` carries a `fetchedAt: Date` purely for diagnostics —
    /// it must NOT participate in the comparison or every refresh
    /// would flag every upstream Spoon as "Update available" simply
    /// because the latest probe ran later than the install probe.
    static func updateAvailable(
        installed: InstalledRef?,
        latest: InstalledRef?
    ) -> Bool {
        guard let installed = installed, let latest = latest else {
            return false
        }
        return installed.identityValue != latest.identityValue
    }

    /// Stable identity of an `InstalledRef` for comparison purposes —
    /// the git SHA or the ETag string, with the case as a prefix so
    /// a SHA and an ETag with the same string aren't accidentally
    /// considered equal.
    var identityValue: String {
        switch self {
        case .gitCommit(let sha):    return "gitCommit:" + sha
        case .zipETag(let value, _): return "zipETag:"   + value
        }
    }
}
