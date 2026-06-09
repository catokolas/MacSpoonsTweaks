import Foundation

/// Encodes a `ConfigValue` (or a few primitive types directly) as a Lua
/// expression suitable for embedding inside a script handed to
/// `hs -c "<script>"`.
///
/// Two invariants the encoder must hold:
///
/// 1. **No shell injection.** The output is Lua source, not shell. The
///    bridge always passes the script as a single `Process` argument, so
///    the shell never sees these bytes — but defense in depth: control
///    chars (especially backticks, dollar signs, etc.) appear here only
///    inside Lua string literals where they are inert.
///
/// 2. **No Lua injection.** A `ConfigValue.string("\"); evil() --")` must
///    NOT escape the surrounding string literal and inject code. All
///    user-supplied strings are quoted with `"` and contain `"`, `\`,
///    and any control character (≤ 0x1F or 0x7F) as Lua decimal escape
///    sequences `\ddd`.
///
/// The `.luaLiteral` case is the explicit escape hatch: the caller has
/// already validated the snippet by round-tripping it through `hs -c`,
/// so we pass it through verbatim.
public enum LuaLiteral {

    public static func encode(_ value: ConfigValue) -> String {
        switch value {
        case .null:                return "nil"
        case .bool(let b):         return b ? "true" : "false"
        case .int(let i):          return String(i)
        case .number(let d):       return formatDouble(d)
        case .string(let s):       return encodeString(s)
        case .stringList(let arr): return encodeStringList(arr)
        case .object(let dict):    return encodeTable(dict)
        case .luaLiteral(let raw): return raw
        }
    }

    /// Convenience for top-level dictionaries (e.g. the `:configure` arg).
    public static func encodeTable(_ table: [String: ConfigValue]) -> String {
        if table.isEmpty { return "{}" }
        // Sorted-key output keeps generated snippets diff-stable.
        let keys = table.keys.sorted()
        var parts: [String] = []
        for key in keys {
            let v = table[key]!
            parts.append("\(encodeKey(key)) = \(encode(v))")
        }
        return "{ " + parts.joined(separator: ", ") + " }"
    }

    /// Encode a list of strings as a Lua sequence `{ "a", "b", "c" }`.
    public static func encodeStringList(_ list: [String]) -> String {
        if list.isEmpty { return "{}" }
        return "{ " + list.map(encodeString).joined(separator: ", ") + " }"
    }

    /// Encode a Lua string literal. Always `"`-quoted. Escapes `\` and `"`
    /// directly; control characters (≤ 0x1F or 0x7F) as `\ddd` decimal.
    /// UTF-8 multi-byte sequences pass through unchanged — we accumulate
    /// into a byte buffer so a multi-byte scalar isn't fragmented into
    /// Latin-1 codepoints.
    public static func encodeString(_ s: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.utf8.count + 2)
        bytes.append(0x22)  // opening "
        for byte in s.utf8 {
            switch byte {
            case 0x5C:                       // backslash
                bytes.append(contentsOf: [0x5C, 0x5C])
            case 0x22:                       // double-quote
                bytes.append(contentsOf: [0x5C, 0x22])
            case 0x0A:                       // \n
                bytes.append(contentsOf: [0x5C, 0x6E])
            case 0x0D:                       // \r
                bytes.append(contentsOf: [0x5C, 0x72])
            case 0x09:                       // \t
                bytes.append(contentsOf: [0x5C, 0x74])
            case 0x00...0x1F, 0x7F:          // other controls → \ddd
                let escape = String(format: "\\%03d", byte)
                bytes.append(contentsOf: escape.utf8)
            default:
                bytes.append(byte)
            }
        }
        bytes.append(0x22)  // closing "
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Pick bareword form `key = ...` when `key` is a Lua-safe identifier
    /// and not a reserved word; otherwise quote it as `["..."] = ...`.
    public static func encodeKey(_ key: String) -> String {
        if isLuaIdentifier(key) && !luaReservedWords.contains(key) {
            return key
        }
        return "[" + encodeString(key) + "]"
    }

    // MARK: - Internals

    private static func formatDouble(_ d: Double) -> String {
        // Match the Lua-side numeric expectations:
        //   * Match the float-vs-int distinction: ConfigValue.number is
        //     ALWAYS emitted with a decimal point or exponent so the Lua
        //     parser stores it as a float, not an integer (Lua 5.3+
        //     tracks integer subtype separately).
        //   * Shortest round-trip representation: try printf %.1g .. %.17g
        //     and pick the first that re-parses to the same Double, then
        //     ensure it still reads as a float on the Lua side.
        if d.isNaN { return "(0/0)" }
        if d.isInfinite { return d > 0 ? "math.huge" : "-math.huge" }
        for precision in 1...17 {
            let s = String(format: "%.\(precision)g", d)
            if Double(s) == d {
                return floatForm(s)
            }
        }
        return floatForm(String(format: "%.17g", d))
    }

    /// Ensure the string parses as a Lua float (has `.` or `e`). `5` would
    /// become `5.0` so Lua sees a float; `5.0` and `5e0` already qualify.
    private static func floatForm(_ s: String) -> String {
        if s.contains(".") || s.contains("e") || s.contains("E") {
            return s
        }
        return s + ".0"
    }

    private static func isLuaIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        if !(first == "_" || (first >= "A" && first <= "Z")
                          || (first >= "a" && first <= "z")) {
            return false
        }
        for scalar in s.unicodeScalars.dropFirst() {
            let isDigit = scalar >= "0" && scalar <= "9"
            let isAlpha = (scalar >= "A" && scalar <= "Z")
                       || (scalar >= "a" && scalar <= "z")
            if !(isDigit || isAlpha || scalar == "_") { return false }
        }
        return true
    }

    private static let luaReservedWords: Set<String> = [
        "and", "break", "do", "else", "elseif", "end", "false", "for",
        "function", "goto", "if", "in", "local", "nil", "not", "or",
        "repeat", "return", "then", "true", "until", "while",
    ]
}
