import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("LuaValidator")
struct LuaValidatorTests {

    // MARK: - Script construction

    @Test
    func scriptWrapsExpressionInTypeReturningClosure() {
        // The wrap shape MUST match plan §LuaLiteralEditor exactly so
        // table-valued inputs (which need the leading `(`) survive.
        let script = LuaValidator.validationScript(for: "{1, 2, 3}")
        #expect(script ==
                "return (function() local v = ({1, 2, 3}); return type(v) end)()")
    }

    @Test
    func scriptForSimpleExpression() {
        let script = LuaValidator.validationScript(for: "42")
        #expect(script ==
                "return (function() local v = (42); return type(v) end)()")
    }

    // MARK: - Runner extension (mocked)

    /// A LuaRunner that returns canned output or throws a canned error.
    final class StubRunner: LuaRunner, @unchecked Sendable {
        var output: String?
        var thrownError: (any Error)?
        var lastScript: String?

        func runLua(_ script: String, timeout: TimeInterval)
        async throws -> String {
            lastScript = script
            if let e = thrownError { throw e }
            return output ?? ""
        }
    }

    @Test
    func validateLuaReportsOkWithDetectedType() async {
        let runner = StubRunner()
        runner.output = "table"
        let result = await runner.validateLua("{1, 2, 3}")
        #expect(result == .ok(luaType: "table"))
        #expect(runner.lastScript?.contains("{1, 2, 3}") == true)
    }

    @Test
    func validateLuaReportsSyntaxErrorOnLuaErrorFromBridge() async {
        let runner = StubRunner()
        runner.thrownError = HammerspoonBridgeError.luaError(
            stderr: "<command>:1: ')' expected near '}'")
        let result = await runner.validateLua("{1, 2")
        if case .syntaxError(let msg) = result {
            #expect(msg.contains("expected"))
        } else {
            Issue.record("expected .syntaxError, got \(result)")
        }
    }

    @Test
    func validateLuaReportsOtherForNonLuaErrors() async {
        // Process launch failure, timeout, CLI missing — anything not
        // .luaError — degrades to .other so the chip stays neutral.
        let runner = StubRunner()
        runner.thrownError = HammerspoonBridgeError.cliMissing
        let result = await runner.validateLua("42")
        if case .other = result {} else {
            Issue.record("expected .other, got \(result)")
        }
    }

    @Test
    func validateLuaTreatsEmptyInputAsSyntaxError() async {
        let runner = StubRunner()
        runner.output = "nil"   // wouldn't be called for empty input
        let cases = ["", "   ", "\n  \t"]
        for input in cases {
            let result = await runner.validateLua(input)
            if case .syntaxError(let msg) = result {
                #expect(msg == "(empty)")
            } else {
                Issue.record("expected empty result for \"\(input)\", got \(result)")
            }
            // Should NOT have called the runner.
            #expect(runner.lastScript == nil,
                    "empty input must short-circuit before runLua")
            runner.lastScript = nil
        }
    }

    // MARK: - Integration against the live bridge

    @Test
    func integrationLiveBridgeRoundTripsCommonTypes() async throws {
        // Skip cleanly when no Hammerspoon is reachable. Same pattern
        // as HammerspoonBridgeIntegrationTests.
        let env = HammerspoonEnvironment()
        guard let bridge = HammerspoonBridge(status: env.snapshot()) else {
            return
        }
        // Probe: ping.
        let ping = try? await bridge.runLua("return 'pong'", timeout: 3)
        guard ping == "pong" else { return }

        // Each pair: (input, expected Lua type name).
        let cases: [(String, String)] = [
            ("42",           "number"),
            ("\"hello\"",    "string"),
            ("true",         "boolean"),
            ("{1, 2}",       "table"),
            ("function() return 1 end", "function"),
        ]
        for (input, expectedType) in cases {
            let result = await bridge.validateLua(input)
            #expect(result == .ok(luaType: expectedType),
                    "input \"\(input)\" → \(result)")
        }

        // Invalid input.
        let badResult = await bridge.validateLua("{1, 2")
        if case .syntaxError = badResult {} else {
            Issue.record("expected syntaxError for invalid Lua, got \(badResult)")
        }
    }
}
