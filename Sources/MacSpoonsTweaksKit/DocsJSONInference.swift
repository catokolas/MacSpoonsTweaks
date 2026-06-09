import Foundation

// MARK: - Upstream docs.json shapes

/// One entry in the upstream `docs/docs.json` array — corresponds to a
/// single Spoon. Matches the format Hammerspoon's doc generator emits:
/// see `Hammerspoon/Spoons/docs/docs.json`.
public struct UpstreamModule: Decodable, Sendable {
    public let name: String
    public let desc: String?
    public let doc:  String?
    public let type: String                 // expected "Module"
    public let Method:   [UpstreamMethod]?
    public let Variable: [UpstreamVariable]?
    public let Function: [UpstreamMethod]?  // class-level functions; we only check :start/:configure etc on Method
}

public struct UpstreamVariable: Decodable, Sendable {
    public let name: String
    public let desc: String?
    public let doc:  String?
    public let signature: String?
}

public struct UpstreamMethod: Decodable, Sendable {
    public let name: String
    public let desc: String?
    public let signature: String?
}

// MARK: - Inference

/// Builds `SpoonCatalogEntry` rows from a decoded upstream docs.json
/// array. Pure — caller (HammerspoonOfficialSource) does the HTTP.
public enum DocsJSONInference {

    public static let sourceID = "hammerspoon-official"

    public static func entries(
        from modules: [UpstreamModule]
    ) -> [SpoonCatalogEntry] {
        return modules
            .filter { $0.type == "Module" }
            .map { entry(from: $0) }
            .sorted { $0.name < $1.name }
    }

    private static func entry(from m: UpstreamModule) -> SpoonCatalogEntry {
        return SpoonCatalogEntry(
            id:        "\(sourceID):\(m.name)",
            name:      m.name,
            sourceID:  sourceID,
            metadata:  SpoonMetadata(
                version:     "",                 // not surfaced in upstream docs
                description: m.desc,
                author:      nil,
                homepage:    nil,
                license:     nil),
            lifecycle: lifecycle(from: m),
            config:    config(from: m),
            hotkeys:   [],                       // upstream docs don't document
                                                 // action names — defer to overrides
            provenance: .inferred)
    }

    // MARK: - Lifecycle

    /// Method presence tells us which lifecycle hooks the Spoon
    /// implements. Names match Hammerspoon convention.
    static func lifecycle(from m: UpstreamModule) -> Lifecycle {
        let methodNames = Set((m.Method ?? []).map(\.name))
        return Lifecycle(
            hasStart:     methodNames.contains("start"),
            hasStop:      methodNames.contains("stop"),
            hasToggle:    methodNames.contains("toggle"),
            hasConfigure: methodNames.contains("configure"),
            // No upstream signal for "event-driven" — default to false.
            // The snippet generator emits `start = true` from
            // `hasStart`, which is correct for both lifecycle styles.
            eventDriven:  false)
    }

    // MARK: - Config

    static func config(from m: UpstreamModule) -> [ConfigField] {
        return (m.Variable ?? []).map { inferField(from: $0) }
    }

    /// Three-rule cascade for inferring a ConfigField from an upstream
    /// `Variable` entry:
    ///
    ///   1. The upstream docs.json doesn't carry the RHS expression for
    ///      a variable assignment; the only place a default value
    ///      typically appears is the prose desc. Match common phrases
    ///      ("Defaults to X", "Default: X", "(default X)") with a
    ///      regex and map the matched literal to a typed field.
    ///   2. If we can't extract a default, fall back to .luaLiteral so
    ///      the user can still set the field by typing a raw Lua
    ///      expression. The plan's "fallback to free-text editor" rule.
    ///   3. desc itself is used as the field description regardless of
    ///      the inferred type, with the "default" phrase trimmed so it
    ///      doesn't read awkwardly under the form control.
    static func inferField(from v: UpstreamVariable) -> ConfigField {
        let desc = v.desc ?? v.doc ?? ""
        let trimmedDesc = stripDefaultPhrase(desc).trimmingCharacters(
            in: .whitespacesAndNewlines)
        let descOrNil = trimmedDesc.isEmpty ? nil : trimmedDesc

        if let literal = extractDefaultLiteral(from: desc) {
            if let bool = parseBoolLiteral(literal) {
                return .bool(BoolField(
                    key: v.name, label: v.name, description: descOrNil,
                    advanced: nil, requires: nil, default: bool))
            }
            if let int = parseIntLiteral(literal) {
                return .int(IntField(
                    key: v.name, label: v.name, description: descOrNil,
                    advanced: nil, requires: nil, default: int,
                    min: nil, max: nil, step: nil, unit: nil))
            }
            if let dbl = parseDoubleLiteral(literal) {
                return .number(NumberField(
                    key: v.name, label: v.name, description: descOrNil,
                    advanced: nil, requires: nil, default: dbl,
                    min: nil, max: nil, step: nil, unit: nil))
            }
            if let str = parseStringLiteral(literal) {
                return .string(StringField(
                    key: v.name, label: v.name, description: descOrNil,
                    advanced: nil, requires: nil, default: str,
                    itemPlaceholder: nil))
            }
        }

        // Fallback per plan: free-text Lua editor with hint.
        return .luaLiteral(LuaLiteralField(
            key: v.name, label: v.name, description: descOrNil,
            advanced: nil, requires: nil,
            default: nil,
            luaHint: "Free-text Lua value (e.g. `42`, `\"foo\"`, `{ ... }`)"))
    }

    // MARK: - Default-phrase extraction

    private static let defaultPhraseRegex: NSRegularExpression = {
        // Matches:
        //   * "Defaults to X" / "Defaults to X." / "Defaults to `X`"
        //   * "Default: X" / "Default is X" / "default `X`"
        //   * "(default X)" / "(default: X)"
        // The X capture covers true/false, integers, floats, quoted
        // strings, and backtick-wrapped literals. We deliberately don't
        // try to match Lua tables — those fall through to .luaLiteral.
        let pattern =
            #"(?:Defaults?\s+to|Default(?:\s+is|:)?|\(\s*default[:\s])"#
            + #"\s*`?\s*("#
            + #"true|false"#                       // booleans
            + #"|-?\d+(?:\.\d+)?(?:[eE][+\-]?\d+)?"# // numbers
            + #"|\"(?:\\.|[^"\\])*\""#             // double-quoted strings
            + #"|'(?:\\.|[^'\\])*'"#               // single-quoted strings
            + #")\s*`?"#
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern,
            options: [.caseInsensitive])
    }()

    static func extractDefaultLiteral(from desc: String) -> String? {
        let range = NSRange(desc.startIndex..<desc.endIndex, in: desc)
        guard let match = defaultPhraseRegex.firstMatch(
            in: desc, range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: desc)
        else { return nil }
        return String(desc[captureRange])
    }

    /// Remove the "Defaults to X" sentence fragment from a description
    /// so the inline form caption doesn't show the value twice (the
    /// form control itself displays the current value).
    static func stripDefaultPhrase(_ desc: String) -> String {
        let range = NSRange(desc.startIndex..<desc.endIndex, in: desc)
        let stripped = defaultPhraseRegex.stringByReplacingMatches(
            in: desc, range: range, withTemplate: "")
        // Collapse double spaces that result from the strip, and remove
        // a trailing stranded ".".
        var out = stripped
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasSuffix(".") && !out.hasSuffix("..") {
            // OK to keep trailing periods, but remove a stranded "."
            // that's the entire string after stripping.
            if out == "." { out = "" }
        }
        return out
    }

    // MARK: - Literal parsers

    private static func parseBoolLiteral(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true":  return true
        case "false": return false
        default:      return nil
        }
    }

    private static func parseIntLiteral(_ s: String) -> Int? {
        // Reject if contains decimal point or exponent — those belong
        // to parseDoubleLiteral.
        if s.contains(".") || s.contains("e") || s.contains("E") { return nil }
        return Int(s)
    }

    private static func parseDoubleLiteral(_ s: String) -> Double? {
        // Only accept strings that look like floats; integer-looking
        // strings should have been claimed by parseIntLiteral first.
        if !s.contains(".") && !s.contains("e") && !s.contains("E") {
            return nil
        }
        return Double(s)
    }

    private static func parseStringLiteral(_ s: String) -> String? {
        // Trim matching quotes.
        if (s.hasPrefix("\"") && s.hasSuffix("\""))
            || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return nil
    }
}
