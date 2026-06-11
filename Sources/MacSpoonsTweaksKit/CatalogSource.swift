import Foundation

/// Per-Spoon record after a `CatalogSource` has fetched and normalized
/// its manifest. The rest of the app deals only in `SpoonCatalogEntry`,
/// not in source-specific types.
public struct SpoonCatalogEntry: Identifiable, Sendable {
    public var id:        String                  // "<sourceID>:<name>" — stable across sources
    public var name:      String
    public var sourceID:  String                  // routes install to SpoonInstall's repo of the same name
    public var metadata:  SpoonMetadata
    public var lifecycle: Lifecycle
    public var config:    [ConfigField]
    public var hotkeys:   [HotkeyAction]
    /// Companion native modules this Spoon opportunistically uses.
    /// Empty unless the manifest declared `optionalModules`. Surfaced
    /// in the detail view so the user can install / update them via
    /// the `NativeModuleInstaller`.
    public var optionalModules: [OptionalModule] = []
    /// Known bugs / limitations the maintainer wanted surfaced.
    /// Defaults to `[]` for upstream / inferred entries.
    public var knownIssues:     [KnownIssue]     = []
    public var provenance: ConfigProvenance
}

public struct SpoonMetadata: Sendable {
    public var version:     String
    public var description: String?
    public var author:      String?
    public var homepage:    String?
    public var license:     String?
}

/// Where the config schema came from — surfaced in the UI so the user
/// knows how trustworthy / hand-curated the form is.
public enum ConfigProvenance: Sendable, Equatable {
    case manifest                     // authored by us (HS_SpoonsContrib)
    case override(of: String)         // upstream Spoon with our hand-written override (sourceID)
    case inferred                     // best-effort from upstream docs.json `Variable` entries
}

/// One side of the source abstraction. The app composes a `[CatalogSource]`
/// and merges their outputs into a single deduped sidebar list.
public protocol CatalogSource: Sendable {
    /// Stable identifier for this source (e.g. "catokolas",
    /// "hammerspoon-official"). Used as the SpoonInstall repo name
    /// that `spoon.SpoonInstall:asyncInstallSpoonFromRepo` is called with.
    var id: String { get }

    /// Fetch the latest catalog. Implementations should respect HTTP
    /// caching (ETag / Last-Modified) so re-calling this on launch is
    /// cheap when the upstream hasn't changed.
    func refresh() async throws -> [SpoonCatalogEntry]
}
