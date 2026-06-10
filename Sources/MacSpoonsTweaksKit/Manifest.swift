import Foundation

// MARK: - Top-level catalog

/// Decoded shape of the `spoons.json` document produced by
/// `HS_SpoonsContrib/tools/build-manifest.lua`. App fetches this and
/// turns its contents into `SpoonCatalogEntry` rows for the UI.
public struct SpoonsCatalog: Decodable, Sendable {
    public var schemaVersion: Int
    public var repo:          String
    public var commit:        String?
    public var generatedAt:   String?
    public var spoons:        [SpoonManifest]
    public var overrides:     [String: SpoonManifest]
}

// MARK: - Per-Spoon manifest

public struct SpoonManifest: Decodable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var name:        String
    public var version:     String
    public var description: String?
    public var author:      String?
    public var homepage:    String?
    public var license:     String?

    public var lifecycle: Lifecycle
    public var config:    [ConfigField]
    public var hotkeys:   [HotkeyAction]

    /// Companion native modules this Spoon opportunistically uses.
    /// Empty if the Spoon doesn't depend on any. Defaults to `[]` for
    /// manifests written before the field existed.
    public var optionalModules: [OptionalModule]

    public var id: String { name }

    public init(
        schemaVersion: Int,
        name: String,
        version: String,
        description: String? = nil,
        author: String? = nil,
        homepage: String? = nil,
        license: String? = nil,
        lifecycle: Lifecycle,
        config:  [ConfigField] = [],
        hotkeys: [HotkeyAction] = [],
        optionalModules: [OptionalModule] = []
    ) {
        self.schemaVersion   = schemaVersion
        self.name            = name
        self.version         = version
        self.description     = description
        self.author          = author
        self.homepage        = homepage
        self.license         = license
        self.lifecycle       = lifecycle
        self.config          = config
        self.hotkeys         = hotkeys
        self.optionalModules = optionalModules
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, name, version, description, author, homepage
        case license, lifecycle, config, hotkeys, optionalModules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.name        = try c.decode(String.self, forKey: .name)
        self.version     = try c.decode(String.self, forKey: .version)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.author      = try c.decodeIfPresent(String.self, forKey: .author)
        self.homepage    = try c.decodeIfPresent(String.self, forKey: .homepage)
        self.license     = try c.decodeIfPresent(String.self, forKey: .license)
        self.lifecycle   = try c.decode(Lifecycle.self, forKey: .lifecycle)
        self.config      = try c.decode([ConfigField].self, forKey: .config)
        self.hotkeys     = try c.decode([HotkeyAction].self, forKey: .hotkeys)
        self.optionalModules = try c.decodeIfPresent(
            [OptionalModule].self, forKey: .optionalModules) ?? []
    }
}

public struct Lifecycle: Decodable, Sendable {
    public var hasStart:     Bool
    public var hasStop:      Bool
    public var hasToggle:    Bool
    public var hasConfigure: Bool
    public var eventDriven:  Bool
}

// MARK: - Hotkeys

public struct HotkeyAction: Decodable, Identifiable, Sendable {
    public var action: String
    public var label:  String?
    public var `default`: HotkeyBinding?

    public var id: String { action }
}

public struct HotkeyBinding: Codable, Hashable, Sendable {
    public var mods: [String]
    public var key:  String

    public init(mods: [String], key: String) {
        self.mods = mods
        self.key  = key
    }
}

// MARK: - ConfigField discriminated union

/// Schema of a single configuration knob — distinct from `ConfigValue`,
/// which holds the user's value for it. Dispatched on the `type`
/// discriminator in JSON.
public enum ConfigField: Decodable, Identifiable, Sendable {
    case number(NumberField)
    case int(IntField)
    case bool(BoolField)
    case string(StringField)
    case enumChoice(EnumField)
    case stringList(StringListField)
    case object(ObjectField)
    case luaLiteral(LuaLiteralField)

    public var id: String { key }

    public var key: String {
        switch self {
        case .number(let f):     return f.key
        case .int(let f):        return f.key
        case .bool(let f):       return f.key
        case .string(let f):     return f.key
        case .enumChoice(let f): return f.key
        case .stringList(let f): return f.key
        case .object(let f):     return f.key
        case .luaLiteral(let f): return f.key
        }
    }

    public var label: String? {
        switch self {
        case .number(let f):     return f.label
        case .int(let f):        return f.label
        case .bool(let f):       return f.label
        case .string(let f):     return f.label
        case .enumChoice(let f): return f.label
        case .stringList(let f): return f.label
        case .object(let f):     return f.label
        case .luaLiteral(let f): return f.label
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DiscriminatorKey.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "number":     self = .number(try NumberField(from: decoder))
        case "int":        self = .int(try IntField(from: decoder))
        case "bool":       self = .bool(try BoolField(from: decoder))
        case "string":     self = .string(try StringField(from: decoder))
        case "enum":       self = .enumChoice(try EnumField(from: decoder))
        case "stringList": self = .stringList(try StringListField(from: decoder))
        case "object":     self = .object(try ObjectField(from: decoder))
        case "luaLiteral": self = .luaLiteral(try LuaLiteralField(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown ConfigField type '\(type)'"
            )
        }
    }

    private enum DiscriminatorKey: String, CodingKey { case type }
}

// MARK: - ConfigField cases

/// Common to every concrete ConfigField type — embedded by composition
/// in each struct below.
public struct FieldRequirement: Decodable, Sendable {
    public var key:    String
    public var equals: ConfigValue
}

public struct NumberField: Decodable, Sendable {
    public var key:         String
    public var label:       String?
    public var description: String?
    public var advanced:    Bool?
    public var requires:    FieldRequirement?
    public var `default`:   Double
    public var min:         Double?
    public var max:         Double?
    public var step:        Double?
    public var unit:        String?
}

public struct IntField: Decodable, Sendable {
    public var key:         String
    public var label:       String?
    public var description: String?
    public var advanced:    Bool?
    public var requires:    FieldRequirement?
    public var `default`:   Int
    public var min:         Int?
    public var max:         Int?
    public var step:        Int?
    public var unit:        String?
}

public struct BoolField: Decodable, Sendable {
    public var key:         String
    public var label:       String?
    public var description: String?
    public var advanced:    Bool?
    public var requires:    FieldRequirement?
    public var `default`:   Bool
}

public struct StringField: Decodable, Sendable {
    public var key:             String
    public var label:           String?
    public var description:     String?
    public var advanced:        Bool?
    public var requires:        FieldRequirement?
    public var `default`:       String?
    public var itemPlaceholder: String?
}

public struct EnumOption: Decodable, Sendable {
    public var value: String
    public var label: String
}

public struct EnumField: Decodable, Sendable {
    public var key:         String
    public var label:       String?
    public var description: String?
    public var advanced:    Bool?
    public var requires:    FieldRequirement?
    public var `default`:   String
    public var `enum`:      [EnumOption]
}

public struct StringListField: Decodable, Sendable {
    public var key:             String
    public var label:           String?
    public var description:     String?
    public var advanced:        Bool?
    public var requires:        FieldRequirement?
    public var `default`:       [String]
    public var itemPlaceholder: String?
}

public struct ObjectField: Decodable, Sendable {
    public var key:         String
    public var label:       String?
    public var description: String?
    public var advanced:    Bool?
    public var requires:    FieldRequirement?
    public var collapsible: Bool?
    public var fields:      [ConfigField]
}

public struct LuaLiteralField: Decodable, Sendable {
    public var key:         String
    public var label:       String?
    public var description: String?
    public var advanced:    Bool?
    public var requires:    FieldRequirement?
    public var `default`:   String?
    public var luaHint:     String?
}
