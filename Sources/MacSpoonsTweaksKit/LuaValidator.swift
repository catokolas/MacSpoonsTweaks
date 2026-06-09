import Foundation

/// Per-keystroke validation result for the `LuaLiteralEditor`. The
/// editor's chip / status indicator dispatches on this.
public enum LuaValidationResult: Equatable, Sendable {
    /// The input parses and evaluates. Includes the detected Lua type
    /// name (`"string"`, `"number"`, `"boolean"`, `"table"`,
    /// `"function"`, …) for display alongside the success indicator.
    case ok(luaType: String)
    /// `hs -c` exited non-zero — almost always a Lua syntax error or
    /// runtime error from the wrapped evaluation. Carries the raw
    /// stderr line so the editor can surface it inline.
    case syntaxError(String)
    /// Any other failure: timeout, process launch failure, no live
    /// Hammerspoon. The editor shows a neutral state in this case
    /// rather than red — the user can't fix "Hammerspoon isn't
    /// running" by changing their snippet.
    case other(String)
}

/// Builders + result parsers for the round-trip the `LuaLiteralEditor`
/// uses to validate user input. Splitting these into pure functions
/// makes the wrap exact and unit-testable; the editor view just
/// orchestrates async I/O around them.
public enum LuaValidator {

    /// Wrap the user's expression in a closure that evaluates it and
    /// returns the resulting value's Lua type name. If the input is
    /// not a valid expression (e.g. a statement, or unbalanced
    /// braces), `hs -c` reports a Lua parse error which the bridge
    /// surfaces as `.luaError`.
    ///
    /// The extra `(...)` around `input` makes table-typed inputs
    /// (`{1, 2, 3}`) parse correctly — without it, the assignment
    /// `local v = {1, 2, 3}` is a statement (still valid), but other
    /// expressions need to be grouped.
    public static func validationScript(for input: String) -> String {
        return "return (function() local v = (\(input)); return type(v) end)()"
    }
}

// MARK: - LuaRunner sugar

public extension LuaRunner {
    /// Run the wrapped expression and turn the runner's success / error
    /// into a `LuaValidationResult`. Used by `LuaLiteralEditor`.
    func validateLua(
        _ input: String,
        timeout: TimeInterval = 3
    ) async -> LuaValidationResult {
        // Empty / whitespace input → don't bother round-tripping; an
        // empty wrap evaluates to nil, which would look like "type is
        // nil" — not useful UX. Surface as syntax error so the chip
        // shows "—" / "empty".
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .syntaxError("(empty)")
        }
        do {
            let typeName = try await runLua(
                LuaValidator.validationScript(for: input),
                timeout: timeout)
            return .ok(luaType: typeName)
        } catch let HammerspoonBridgeError.luaError(stderr) {
            return .syntaxError(stderr)
        } catch {
            return .other(String(describing: error))
        }
    }
}
