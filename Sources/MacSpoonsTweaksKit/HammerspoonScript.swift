import Foundation

/// Pure functions that build the Lua snippets `HammerspoonBridge` hands
/// to `hs -c`. Split from the bridge so the snippet shapes are unit-
/// testable without Hammerspoon running.
///
/// Everything here is deterministic; the bridge owns I/O.
public enum HammerspoonScript {

    // MARK: Lifecycle

    /// `hs.loadSpoon("X")`. Idempotent on the Hammerspoon side.
    public static func loadSpoon(_ name: String) -> String {
        return "hs.loadSpoon(\(LuaLiteral.encodeString(name)))"
    }

    public static func startSpoon(_ name: String) -> String {
        return "spoon.\(name):start()"
    }

    public static func stopSpoon(_ name: String) -> String {
        return "spoon.\(name):stop()"
    }

    public static func reload() -> String {
        return "hs.reload()"
    }

    // MARK: Config

    /// Build the script that applies `config` to `spoon.<spoonName>`.
    ///
    /// Two cases:
    ///   * `hasConfigure == true` — emit `spoon.X:configure({...})`. The
    ///     receiving Spoon does a deep merge (the `:configure` method
    ///     we ship in HS_SpoonsContrib does this), so nested keys not
    ///     mentioned in `config` keep their current values.
    ///   * `hasConfigure == false` — emit one assignment per top-level
    ///     key: `spoon.X.field = value`. Upstream Spoons that don't
    ///     expose `:configure` expect this flat form. A nested table
    ///     value here REPLACES the existing field — no merge.
    ///
    /// Top-level value must be `.object(...)`. Anything else is a
    /// programming error (the schema always wraps fields in an object).
    public static func configure(
        spoon spoonName: String,
        config: ConfigValue,
        hasConfigure: Bool
    ) -> String {
        guard case .object(let fields) = config else {
            // Empty value → no-op script. Keeps callers from special-
            // casing the "nothing to apply" path.
            return ""
        }

        if fields.isEmpty { return "" }

        if hasConfigure {
            return "spoon.\(spoonName):configure(" +
                   LuaLiteral.encodeTable(fields) + ")"
        }

        // Sorted keys for stable script diffs.
        let lines = fields.keys.sorted().map { key in
            let v = LuaLiteral.encode(fields[key]!)
            return "spoon.\(spoonName)\(propertyAccess(key)) = \(v)"
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Hotkeys

    /// `spoon.<spoonName>:bindHotkeys({ action = { {"mod1","mod2"}, "key" }, … })`.
    ///
    /// Caller-supplied `mapping` keys are Spoon-defined action names
    /// (e.g. `"toggle"`, `"space_left"`). Values are the user's selected
    /// shortcut for that action.
    ///
    /// Returns `""` for an empty mapping so the caller can blindly
    /// concatenate this into a script without needing to know whether
    /// any bindings were configured.
    public static func bindHotkeys(
        spoon spoonName: String,
        mapping: [String: HotkeyBinding]
    ) -> String {
        if mapping.isEmpty { return "" }

        let entries = mapping.keys.sorted().map { action -> String in
            let b = mapping[action]!
            let modsList: ConfigValue = .stringList(b.mods)
            let mods = LuaLiteral.encode(modsList)
            let key = LuaLiteral.encodeString(b.key)
            return "\(LuaLiteral.encodeKey(action)) = { \(mods), \(key) }"
        }
        return "spoon.\(spoonName):bindHotkeys({ "
             + entries.joined(separator: ", ")
             + " })"
    }

    // MARK: Property reads (used by tests + Diagnostics view)

    /// `return spoon.<spoonName>.<field>` (or `["…"]` for non-identifier
    /// segments) — runs through `hs -c` and produces the value's string
    /// form on stdout. Useful for verifying a live apply landed.
    /// `fieldPath` is a dot-separated path; pass `"middleClick.multiFinger.fingerCount"`
    /// for a deeply nested field.
    public static func readProperty(spoon spoonName: String,
                                    fieldPath: String) -> String {
        let access = fieldPath
            .split(separator: ".")
            .map { propertyAccess(String($0)) }
            .joined()
        return "return spoon.\(spoonName)\(access)"
    }

    // MARK: - Internals

    /// Property-access form for a single field segment, with the joining
    /// punctuation included so callers can simply concatenate.
    ///
    /// * Identifier-safe, non-reserved names → `.field` (with leading dot)
    /// * Anything else → `["field"]` (no leading dot — bracket form
    ///   binds directly to the preceding expression in Lua)
    private static func propertyAccess(_ field: String) -> String {
        let encoded = LuaLiteral.encodeKey(field)
        return encoded.hasPrefix("[") ? encoded : ".\(encoded)"
    }
}
