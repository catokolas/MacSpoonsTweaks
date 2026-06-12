import Foundation

/// Persisted app state. Lives at
/// `~/Library/Application Support/MacSpoonsTweaks/state.json` in
/// production. Only non-default config values are stored under
/// `spoons[name].config` so the file (and the derived `mac_spoons_tweaks.lua`
/// snippet) stays diff-stable when manifest defaults change upstream.
public struct AppState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var lastCatalogFetch: [String: Date]
    public var catalogETags:     [String: String]
    public var spoons:           [String: SpoonState]

    /// Installed companion native modules, keyed by `OptionalModule.name`
    /// (e.g. `"hs._ckol.multitouch"`). Tracks the GitHub release tag
    /// that's currently on disk so the catalog refresh can flag
    /// "Update available". Defaults to `[:]` for state files written
    /// before this field existed.
    public var nativeModules:    [String: NativeModuleState]

    /// User-added Spoon catalogs beyond the built-in catokolas + official
    /// pair. Order is preserved so the user controls precedence in the
    /// sidebar merge. Defaults to `[]` for older state files.
    public var customCatalogs:   [CustomCatalogConfig]

    /// User-selected font-size preset. Mapped to SwiftUI's
    /// `DynamicTypeSize` via `FontSizePreset.dynamicTypeSize` and
    /// applied at every rendering surface so every text scales
    /// together. Defaults to `.xLarge` (matches the pre-feature
    /// hardcoded value) so existing installs don't regress.
    public var fontSize:         FontSizePreset

    public init(
        schemaVersion: Int = 1,
        lastCatalogFetch: [String: Date] = [:],
        catalogETags:     [String: String] = [:],
        spoons:           [String: SpoonState] = [:],
        nativeModules:    [String: NativeModuleState] = [:],
        customCatalogs:   [CustomCatalogConfig] = [],
        fontSize:         FontSizePreset = .xLarge
    ) {
        self.schemaVersion    = schemaVersion
        self.lastCatalogFetch = lastCatalogFetch
        self.catalogETags     = catalogETags
        self.spoons           = spoons
        self.nativeModules    = nativeModules
        self.customCatalogs   = customCatalogs
        self.fontSize         = fontSize
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, lastCatalogFetch, catalogETags, spoons
        case nativeModules, customCatalogs, fontSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion    = try c.decode(Int.self, forKey: .schemaVersion)
        self.lastCatalogFetch = try c.decode(
            [String: Date].self, forKey: .lastCatalogFetch)
        self.catalogETags     = try c.decode(
            [String: String].self, forKey: .catalogETags)
        self.spoons           = try c.decode(
            [String: SpoonState].self, forKey: .spoons)
        self.nativeModules    = try c.decodeIfPresent(
            [String: NativeModuleState].self, forKey: .nativeModules) ?? [:]
        self.customCatalogs   = try c.decodeIfPresent(
            [CustomCatalogConfig].self, forKey: .customCatalogs) ?? []
        self.fontSize         = try c.decodeIfPresent(
            FontSizePreset.self, forKey: .fontSize) ?? .xLarge
    }
}

/// Five-stop preset ladder for the user-adjustable font size in the
/// sidebar header. Mapped to SwiftUI's `DynamicTypeSize` at the
/// rendering surfaces; persisted as a stable raw string token so
/// `state.json` survives renames of SwiftUI's enum.
public enum FontSizePreset: String, Codable, CaseIterable, Equatable, Sendable {
    case standard       = "standard"
    case xLarge         = "xLarge"
    case xxLarge        = "xxLarge"
    case xxxLarge       = "xxxLarge"
    case accessibility1 = "accessibility1"

    /// Human-friendly label surfaced in the A− / A+ button tooltips.
    public var label: String {
        switch self {
        case .standard:       return "Standard"
        case .xLarge:         return "Larger"
        case .xxLarge:        return "Even larger"
        case .xxxLarge:       return "Largest"
        case .accessibility1: return "Accessibility"
        }
    }
}

/// User-added Spoon catalog descriptor. Each entry expands to a
/// `UserCatalogSource` that fetches a `SpoonsCatalog`-shape JSON from a
/// GitHub repo at
/// `https://raw.githubusercontent.com/<owner>/<repo>/<branch>/spoons.json`.
/// The same repo is registered with SpoonInstall as a `RepoRef.custom`
/// so users can install Spoons from it.
public struct CustomCatalogConfig: Codable, Equatable, Sendable {
    public var owner:       String
    public var repo:        String
    public var branch:      String
    public var description: String?
    public var enabled:     Bool

    /// Stable identifier — `"owner/repo"`. Used as the source ID
    /// (prefixed with `"user:"`) and as the SpoonInstall repo name.
    public var id: String { "\(owner)/\(repo)" }

    public init(
        owner: String,
        repo: String,
        branch: String = "main",
        description: String? = nil,
        enabled: Bool = true
    ) {
        self.owner       = owner
        self.repo        = repo
        self.branch      = branch
        self.description = description
        self.enabled     = enabled
    }
}

/// One row of `AppState.nativeModules`. Records which release tag of a
/// companion native module is currently installed at
/// `~/.hammerspoon/<OptionalModule.installSubdir>`.
public struct NativeModuleState: Codable, Equatable, Sendable {
    public var installedVersion: String
    public var installedAt:      Date

    public init(installedVersion: String, installedAt: Date) {
        self.installedVersion = installedVersion
        self.installedAt      = installedAt
    }
}

public struct SpoonState: Codable, Equatable, Sendable {
    /// CatalogSource that owns this Spoon (e.g. "catokolas", "hammerspoon-official").
    public var sourceID: String

    /// Whether this Spoon should be enabled in the generated
    /// `mac_spoons_tweaks.lua`. Always reflects user intent — never used
    /// to gate live applies (those go through the bridge directly).
    public var enabled: Bool

    /// User has temporarily paused the Spoon. `enabled` stays true (the
    /// Spoon remains in the snippet, configured, with its hotkeys bound),
    /// but the snippet omits `start = true` so Hammerspoon reloads leave
    /// it dormant. `SpoonOrchestrator.setPaused` flips this and drives
    /// `:stop()` / `:start()` live.
    public var paused: Bool

    /// What version of the Spoon is currently installed locally, or
    /// `nil` if not installed.
    public var installedRef: InstalledRef?

    /// Top-level `ConfigField.key` list captured from the catalog at
    /// install time. The `CatalogDriftDetector` compares this against
    /// the current catalog entry to surface added / removed fields
    /// when the catalog has churned since install. `nil` for entries
    /// installed before this field existed.
    public var installedSchemaKeys: [String]?

    /// User-supplied config values. Stored as a flat dictionary keyed
    /// by ConfigField.key. Only fields whose value differs from the
    /// manifest's `default` should be present here.
    public var config: [String: ConfigValue]

    /// User-supplied hotkey bindings, keyed by action name.
    public var hotkeys: [String: HotkeyBinding]

    /// User's override of the manifest's `activateHotkey`. Nil means
    /// "use the manifest default". Mirrors the per-action `hotkeys`
    /// semantic: clearing the override falls back to the maintainer's
    /// chord.
    public var activateHotkeyOverride: HotkeyBinding?

    public init(
        sourceID: String,
        enabled: Bool = false,
        paused: Bool = false,
        installedRef: InstalledRef? = nil,
        installedSchemaKeys: [String]? = nil,
        config: [String: ConfigValue] = [:],
        hotkeys: [String: HotkeyBinding] = [:],
        activateHotkeyOverride: HotkeyBinding? = nil
    ) {
        self.sourceID               = sourceID
        self.enabled                = enabled
        self.paused                 = paused
        self.installedRef           = installedRef
        self.installedSchemaKeys    = installedSchemaKeys
        self.config                 = config
        self.hotkeys                = hotkeys
        self.activateHotkeyOverride = activateHotkeyOverride
    }

    // Custom decoder so `paused` defaults to false on pre-existing
    // `state.json` files written before the field existed.
    private enum CodingKeys: String, CodingKey {
        case sourceID, enabled, paused, installedRef
        case installedSchemaKeys, config, hotkeys, activateHotkeyOverride
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceID = try c.decode(String.self, forKey: .sourceID)
        self.enabled  = try c.decode(Bool.self,   forKey: .enabled)
        self.paused   = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        self.installedRef = try c.decodeIfPresent(
            InstalledRef.self, forKey: .installedRef)
        self.installedSchemaKeys = try c.decodeIfPresent(
            [String].self, forKey: .installedSchemaKeys)
        self.config = try c.decode(
            [String: ConfigValue].self, forKey: .config)
        self.hotkeys = try c.decode(
            [String: HotkeyBinding].self, forKey: .hotkeys)
        self.activateHotkeyOverride = try c.decodeIfPresent(
            HotkeyBinding.self, forKey: .activateHotkeyOverride)
    }
}

/// Discriminated union recording HOW the installed Spoon was tracked.
/// `gitCommit` is for our `catokolas` repo (compare against the source
/// subdir's HEAD commit); `zipETag` is for upstream zip downloads
/// (compare against the HEAD ETag/Last-Modified).
public enum InstalledRef: Equatable, Sendable {
    case gitCommit(String)
    case zipETag(value: String, fetchedAt: Date)
}

extension InstalledRef: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, value, fetchedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind  = try c.decode(String.self, forKey: .kind)
        let value = try c.decode(String.self, forKey: .value)
        switch kind {
        case "gitCommit":
            self = .gitCommit(value)
        case "zipETag":
            let date = try c.decode(Date.self, forKey: .fetchedAt)
            self = .zipETag(value: value, fetchedAt: date)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "Unknown InstalledRef kind '\(kind)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .gitCommit(let sha):
            try c.encode("gitCommit", forKey: .kind)
            try c.encode(sha, forKey: .value)
        case .zipETag(let etag, let date):
            try c.encode("zipETag", forKey: .kind)
            try c.encode(etag, forKey: .value)
            try c.encode(date, forKey: .fetchedAt)
        }
    }
}

// MARK: - Store

/// Reads / writes `AppState` to disk. Writes are atomic (Foundation
/// writes the JSON to a temp file in the same directory and then
/// renames over the target). A missing file is treated as a fresh state.
public final class StateStore: @unchecked Sendable {

    public let path: URL

    public init(path: URL = StateStore.defaultPath()) {
        self.path = path
    }

    public static func defaultPath() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("MacSpoonsTweaks")
            .appendingPathComponent("state.json")
    }

    /// Load the state. Returns a default-empty `AppState` if the file
    /// doesn't exist; throws on any other read or decode failure.
    public func load() throws -> AppState {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return AppState()
        }
        let data = try Data(contentsOf: path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppState.self, from: data)
    }

    /// Atomically write the state. Creates the containing directory if
    /// missing. Writes through a temp file + rename so a crash mid-write
    /// can't leave a half-written state.json.
    public func save(_ state: AppState) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: path, options: [.atomic])
    }

    /// Convenience: load, mutate, save. Returns the new state.
    @discardableResult
    public func update(
        _ mutate: (inout AppState) throws -> Void
    ) throws -> AppState {
        var s = try load()
        try mutate(&s)
        try save(s)
        return s
    }
}
