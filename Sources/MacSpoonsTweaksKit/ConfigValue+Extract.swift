import Foundation

/// Type-narrowing extractors used by the SwiftUI form layer to project
/// a typed `Binding<T>` out of a `Binding<ConfigValue>`.
///
/// All accessors return `nil` on type mismatch — the form layer falls
/// back to the field's manifest default in that case. Cross-type
/// promotions are deliberate where the schema treats them as equivalent
/// (`int` ↔ `number`); everything else stays strict.
public extension ConfigValue {

    var asBool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// `.int` returns as-is; `.number` rounds toward zero IF and only if
    /// the value has no fractional component (avoids silently losing
    /// precision when an int field is fed a real float).
    var asInt: Int? {
        switch self {
        case .int(let i):    return i
        case .number(let d):
            guard d.rounded(.towardZero) == d,
                  d >= Double(Int.min), d <= Double(Int.max)
            else { return nil }
            return Int(d)
        default: return nil
        }
    }

    /// `.number` returns as-is; `.int` lossless-promotes to Double.
    var asDouble: Double? {
        switch self {
        case .number(let d): return d
        case .int(let i):    return Double(i)
        default: return nil
        }
    }

    var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var asStringList: [String]? {
        if case .stringList(let a) = self { return a }
        return nil
    }

    /// Returns the inner table for a `.object` value, or `nil` for any
    /// other case. Empty tables (`.object([:])`) round-trip correctly.
    var asObject: [String: ConfigValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    /// Free-text Lua snippet for a `.luaLiteral` value. Distinct from
    /// `asString` so a hand-edited Lua expression isn't mistaken for a
    /// plain string field.
    var asLuaLiteral: String? {
        if case .luaLiteral(let s) = self { return s }
        return nil
    }
}
