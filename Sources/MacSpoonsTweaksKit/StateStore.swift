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

    public init(
        schemaVersion: Int = 1,
        lastCatalogFetch: [String: Date] = [:],
        catalogETags:     [String: String] = [:],
        spoons:           [String: SpoonState] = [:]
    ) {
        self.schemaVersion    = schemaVersion
        self.lastCatalogFetch = lastCatalogFetch
        self.catalogETags     = catalogETags
        self.spoons           = spoons
    }
}

public struct SpoonState: Codable, Equatable, Sendable {
    /// CatalogSource that owns this Spoon (e.g. "catokolas", "hammerspoon-official").
    public var sourceID: String

    /// Whether this Spoon should be enabled in the generated
    /// `mac_spoons_tweaks.lua`. Always reflects user intent — never used
    /// to gate live applies (those go through the bridge directly).
    public var enabled: Bool

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

    public init(
        sourceID: String,
        enabled: Bool = false,
        installedRef: InstalledRef? = nil,
        installedSchemaKeys: [String]? = nil,
        config: [String: ConfigValue] = [:],
        hotkeys: [String: HotkeyBinding] = [:]
    ) {
        self.sourceID            = sourceID
        self.enabled             = enabled
        self.installedRef        = installedRef
        self.installedSchemaKeys = installedSchemaKeys
        self.config              = config
        self.hotkeys             = hotkeys
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
