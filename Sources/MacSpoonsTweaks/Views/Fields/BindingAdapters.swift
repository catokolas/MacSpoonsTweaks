import SwiftUI
import MacSpoonsTweaksKit

/// SwiftUI-side projections from a `[String: ConfigValue]` slot into
/// the typed `Binding<T>` that each per-type field view consumes.
/// Lives in the app target (not Kit) because `Binding` is part of
/// SwiftUI.
///
/// The getter falls back to the manifest default when the slot is
/// missing or holds an incompatible type. The setter always stores
/// using the field's native ConfigValue case so round-trips through
/// state.json preserve the schema's intent (e.g. `.number(5.0)` stays
/// a number even if the value happens to be integral).
extension Binding where Value == [String: ConfigValue] {

    func bool(forKey key: String, default d: Bool) -> Binding<Bool> {
        Binding<Bool>(
            get: { self.wrappedValue[key]?.asBool ?? d },
            set: { self.wrappedValue[key] = .bool($0) }
        )
    }

    func int(forKey key: String, default d: Int) -> Binding<Int> {
        Binding<Int>(
            get: { self.wrappedValue[key]?.asInt ?? d },
            set: { self.wrappedValue[key] = .int($0) }
        )
    }

    func double(forKey key: String, default d: Double) -> Binding<Double> {
        Binding<Double>(
            get: { self.wrappedValue[key]?.asDouble ?? d },
            set: { self.wrappedValue[key] = .number($0) }
        )
    }

    func string(forKey key: String, default d: String) -> Binding<String> {
        Binding<String>(
            get: { self.wrappedValue[key]?.asString ?? d },
            set: { self.wrappedValue[key] = .string($0) }
        )
    }

    func stringList(
        forKey key: String, default d: [String]
    ) -> Binding<[String]> {
        Binding<[String]>(
            get: { self.wrappedValue[key]?.asStringList ?? d },
            set: { self.wrappedValue[key] = .stringList($0) }
        )
    }

    /// Nested-object projection — used by `ObjectGroupView` to recurse
    /// into a child `ConfigFormView`. Always returns a non-nil dict;
    /// writes wrap it back as `.object(...)`.
    func nestedDict(forKey key: String) -> Binding<[String: ConfigValue]> {
        Binding<[String: ConfigValue]>(
            get: { self.wrappedValue[key]?.asObject ?? [:] },
            set: { self.wrappedValue[key] = .object($0) }
        )
    }

    /// Free-text Lua literal — what `LuaLiteralEditor` edits. Falls back
    /// to the manifest default's string form when the slot is empty,
    /// then to "".
    func luaLiteral(
        forKey key: String, default d: String?
    ) -> Binding<String> {
        Binding<String>(
            get: { self.wrappedValue[key]?.asLuaLiteral ?? d ?? "" },
            set: { self.wrappedValue[key] = .luaLiteral($0) }
        )
    }
}
