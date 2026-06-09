import Foundation

/// A typed value tree mirroring `ConfigField`. Round-trips cleanly to:
///   * JSON (state.json — persisted app state)
///   * Lua literals (live apply via `hs -c`, see `LuaLiteral.encode(...)`).
///
/// `ConfigValue` is what a user's actual choice for a config field looks
/// like — distinct from `ConfigField`, which describes the *schema*
/// (label, default, constraints) of the field.
public enum ConfigValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)
    case stringList([String])
    case object([String: ConfigValue])

    /// Free-text Lua literal — the escape hatch used when a field's type
    /// couldn't be inferred from docs.json or when an upstream Spoon
    /// exposes a table-valued Variable we don't model. The encoder must
    /// pass this through verbatim (modulo parse-time validation).
    case luaLiteral(String)
}

// MARK: - Codable

extension ConfigValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let arr = try? c.decode([String].self) {
            self = .stringList(arr)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let obj = try? c.decode([String: ConfigValue].self) {
            // Special case: the `.luaLiteral` encoder writes
            // `{"__luaLiteral": "..."}` — pick that back out so values
            // round-trip across save/load.
            if obj.count == 1,
               case .string(let raw)? = obj["__luaLiteral"] {
                self = .luaLiteral(raw)
            } else {
                self = .object(obj)
            }
        } else {
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "ConfigValue could not be decoded from any " +
                                  "supported JSON type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:                 try c.encodeNil()
        case .bool(let b):          try c.encode(b)
        case .int(let i):           try c.encode(i)
        case .number(let d):        try c.encode(d)
        case .string(let s):        try c.encode(s)
        case .stringList(let a):    try c.encode(a)
        case .object(let o):        try c.encode(o)
        case .luaLiteral(let s):
            // Persist as a tagged object so the decoder can distinguish
            // it from a plain string. (Plain strings round-trip as
            // `.string`; we don't want to lose the "this is raw Lua"
            // tag across reloads.)
            try c.encode(["__luaLiteral": s])
        }
    }
}
