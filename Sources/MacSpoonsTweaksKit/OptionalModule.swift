import Foundation

/// Declared dependency on a companion native Hammerspoon module
/// (the `hs._ckol.*` family). The module is *optional* — the host Spoon
/// `pcall(require, ...)`s it at runtime and falls back gracefully when
/// it's missing — but installing it unlocks features that pure-Lua
/// Hammerspoon can't reach (private SkyLight APIs, MultitouchSupport,
/// CVDisplayLink-paced scroll posting, …).
///
/// Each declaration carries everything the app needs to fetch a
/// pre-built release asset from GitHub and drop it under
/// `~/.hammerspoon/`:
///   * the require name (display only),
///   * the GitHub repo (`owner/repo`) we hit via the Releases API,
///   * the asset name pattern (a simple `*` glob) to pick the right
///     `.zip` asset from a release with multiple files,
///   * the install subdir that should exist after extraction — used
///     to confirm install success and to support `Remove`.
public struct OptionalModule: Decodable, Equatable, Sendable {
    public var name:          String   // "hs._ckol.multitouch"
    public var repo:          String   // "catokolas/HS_ModulesContrib-multitouch"
    public var installSubdir: String   // "hs/_ckol/multitouch"
    public var assetPattern:  String   // "multitouch-*-macos-universal.zip"
    public var description:   String

    public init(
        name: String,
        repo: String,
        installSubdir: String,
        assetPattern:  String,
        description:   String
    ) {
        self.name          = name
        self.repo          = repo
        self.installSubdir = installSubdir
        self.assetPattern  = assetPattern
        self.description   = description
    }
}

/// View-friendly status of a single `OptionalModule`. Derived from
/// the filesystem (does the install dir exist) plus the catalog model's
/// cached latest tag.
public struct NativeModuleStatus: Sendable, Equatable {
    public var installed:    Bool
    public var installedTag: String?
    public var latestTag:    String?

    public init(
        installed: Bool,
        installedTag: String? = nil,
        latestTag:    String? = nil
    ) {
        self.installed    = installed
        self.installedTag = installedTag
        self.latestTag    = latestTag
    }

    /// True iff we have both tags and they disagree.
    public var updateAvailable: Bool {
        guard installed,
              let installed = installedTag,
              let latest    = latestTag
        else { return false }
        return installed != latest
    }
}

/// Matches `pattern` (with `*` as wildcard) against `candidate`, full
/// string. Used to pick the right release asset out of a list.
public func matchAssetPattern(
    _ pattern: String, against candidate: String
) -> Bool {
    let parts = pattern.split(separator: "*",
                              omittingEmptySubsequences: false)
                       .map(String.init)
    guard parts.count > 1 else {
        return candidate == pattern
    }
    var cursor = candidate.startIndex
    // First chunk must match a prefix.
    if let first = parts.first, !first.isEmpty {
        guard candidate.hasPrefix(first) else { return false }
        cursor = candidate.index(cursor, offsetBy: first.count)
    }
    // Last chunk must match a suffix.
    let middle = Array(parts.dropFirst().dropLast())
    for chunk in middle where !chunk.isEmpty {
        guard let range = candidate.range(
            of: chunk, range: cursor..<candidate.endIndex
        ) else { return false }
        cursor = range.upperBound
    }
    if let last = parts.last, !last.isEmpty {
        guard candidate[cursor...].hasSuffix(last) else { return false }
        // Suffix must lie at/after cursor.
        let suffixStart = candidate.index(
            candidate.endIndex, offsetBy: -last.count)
        guard suffixStart >= cursor else { return false }
    }
    return true
}
