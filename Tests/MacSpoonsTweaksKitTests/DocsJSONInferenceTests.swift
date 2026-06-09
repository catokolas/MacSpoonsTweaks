import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("DocsJSONInference")
struct DocsJSONInferenceTests {

    // MARK: - extractDefaultLiteral

    @Test
    func extractDefaultLiteralFromCommonPhrasings() {
        let cases: [(String, String?)] = [
            ("Defaults to true.",                "true"),
            ("Defaults to false.",               "false"),
            ("Defaults to 42",                   "42"),
            ("Defaults to 0.1.",                 "0.1"),
            ("Defaults to -3.5",                 "-3.5"),
            ("Defaults to `false`",              "false"),
            ("Default: 30",                      "30"),
            ("Default is 1.5",                   "1.5"),
            ("(default: 5)",                     "5"),
            ("(default 10)",                     "10"),
            ("Defaults to \"https://example\".", "\"https://example\""),
            ("Defaults to 'foo'",                "'foo'"),
            // No phrase — no extraction.
            ("Just a description.",              nil),
            // Phrase but table value — not extracted, falls to luaLiteral.
            ("Defaults to {1, 2}",               nil),
        ]
        for (input, expected) in cases {
            let actual = DocsJSONInference.extractDefaultLiteral(from: input)
            #expect(actual == expected,
                    "input: \"\(input)\" → got \(String(describing: actual))")
        }
    }

    @Test
    func stripDefaultPhraseRemovesValueButKeepsRest() {
        let result = DocsJSONInference.stripDefaultPhrase(
            "If true, show notifications when state changes. Defaults to false.")
        #expect(result.contains("If true, show notifications"))
        #expect(!result.contains("Defaults to"))
    }

    // MARK: - Per-field inference

    @Test
    func boolVariableInfersBoolField() {
        let v = UpstreamVariable(
            name: "x", desc: "Toggles X. Defaults to true.",
            doc: nil, signature: nil)
        let field = DocsJSONInference.inferField(from: v)
        guard case .bool(let b) = field else {
            Issue.record("expected .bool, got \(field)")
            return
        }
        #expect(b.key == "x")
        #expect(b.default == true)
        #expect(b.description?.contains("Toggles X") == true)
        #expect(b.description?.contains("Defaults") != true,
                "description should strip the default phrase")
    }

    @Test
    func intVariableInfersIntField() {
        let v = UpstreamVariable(
            name: "n", desc: "Number of widgets. Defaults to 42.",
            doc: nil, signature: nil)
        let field = DocsJSONInference.inferField(from: v)
        guard case .int(let i) = field else {
            Issue.record("expected .int, got \(field)")
            return
        }
        #expect(i.default == 42)
        // No min/max can be inferred from prose.
        #expect(i.min == nil && i.max == nil)
    }

    @Test
    func floatVariableInfersNumberField() {
        let v = UpstreamVariable(
            name: "ratio", desc: "Defaults to 1.5", doc: nil, signature: nil)
        let field = DocsJSONInference.inferField(from: v)
        guard case .number(let n) = field else {
            Issue.record("expected .number, got \(field)")
            return
        }
        #expect(n.default == 1.5)
    }

    @Test
    func stringVariableInfersStringField() {
        let v = UpstreamVariable(
            name: "url",
            desc: "Defaults to \"https://example.com\".",
            doc: nil, signature: nil)
        let field = DocsJSONInference.inferField(from: v)
        guard case .string(let s) = field else {
            Issue.record("expected .string, got \(field)")
            return
        }
        #expect(s.default == "https://example.com")
    }

    @Test
    func unparseableVariableFallsBackToLuaLiteral() {
        let v = UpstreamVariable(
            name: "table_config",
            desc: "Configuration table. Defaults to {1, 2, 3}.",
            doc: nil, signature: nil)
        let field = DocsJSONInference.inferField(from: v)
        guard case .luaLiteral(let lua) = field else {
            Issue.record("expected .luaLiteral, got \(field)")
            return
        }
        #expect(lua.key == "table_config")
        #expect(lua.luaHint != nil,
                "hint should guide the user to type a raw Lua value")
    }

    @Test
    func variableWithoutDefaultPhraseFallsBackToLuaLiteral() {
        let v = UpstreamVariable(
            name: "blank",
            desc: "No default mentioned anywhere.",
            doc: nil, signature: nil)
        let field = DocsJSONInference.inferField(from: v)
        if case .luaLiteral = field {} else {
            Issue.record("expected .luaLiteral, got \(field)")
        }
    }

    // MARK: - Lifecycle

    @Test
    func lifecycleReflectsPresenceOfStandardMethods() {
        let m = UpstreamModule(
            name: "X", desc: nil, doc: nil, type: "Module",
            Method: [
                UpstreamMethod(name: "start", desc: nil, signature: nil),
                UpstreamMethod(name: "stop",  desc: nil, signature: nil),
                UpstreamMethod(name: "toggle",desc: nil, signature: nil),
            ],
            Variable: [], Function: [])
        let lifecycle = DocsJSONInference.lifecycle(from: m)
        #expect(lifecycle.hasStart)
        #expect(lifecycle.hasStop)
        #expect(lifecycle.hasToggle)
        #expect(!lifecycle.hasConfigure)
        #expect(!lifecycle.eventDriven)
    }

    @Test
    func lifecycleReportsAllFalseForEmptyMethodList() {
        let m = UpstreamModule(
            name: "X", desc: nil, doc: nil, type: "Module",
            Method: [], Variable: [], Function: [])
        let lifecycle = DocsJSONInference.lifecycle(from: m)
        #expect(!lifecycle.hasStart)
        #expect(!lifecycle.hasStop)
        #expect(!lifecycle.hasToggle)
        #expect(!lifecycle.hasConfigure)
    }

    // MARK: - End-to-end fixture

    @Test
    func endToEndFromFixture() throws {
        let url = try #require(Bundle.module.url(
            forResource: "upstream-docs", withExtension: "json",
            subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let modules = try JSONDecoder()
            .decode([UpstreamModule].self, from: data)
        let entries = DocsJSONInference.entries(from: modules)

        // "NotAModule" filtered out; the three Modules survive.
        #expect(entries.map(\.name).sorted() ==
                ["Caffeine", "EventDriven", "TinyBrowser"])

        // Caffeine: bool variable, has start/stop/toggle.
        let caffeine = try #require(entries.first { $0.name == "Caffeine" })
        #expect(caffeine.sourceID == "hammerspoon-official")
        #expect(caffeine.provenance == .inferred)
        #expect(caffeine.lifecycle.hasStart)
        #expect(caffeine.lifecycle.hasStop)
        #expect(caffeine.lifecycle.hasToggle)
        #expect(!caffeine.lifecycle.hasConfigure)
        #expect(caffeine.config.count == 1)
        if case .bool(let b) = caffeine.config[0] {
            #expect(b.default == false)
        } else {
            Issue.record("Caffeine.show_notifications should be .bool")
        }
        // No upstream hotkey discovery — the field stays empty until an
        // override manifest fills it in.
        #expect(caffeine.hotkeys.isEmpty)

        // TinyBrowser: five variables exercising every inference branch.
        let tiny = try #require(entries.first { $0.name == "TinyBrowser" })
        #expect(tiny.config.count == 5)
        let byKey = Dictionary(
            uniqueKeysWithValues: tiny.config.map { ($0.key, $0) })
        if case .string(let s)? = byKey["default_url"] {
            #expect(s.default == "https://example.com")
        } else { Issue.record("default_url should be .string") }
        if case .int(let i)? = byKey["timeout_seconds"] {
            #expect(i.default == 30)
        } else { Issue.record("timeout_seconds should be .int") }
        if case .number(let n)? = byKey["scale_factor"] {
            #expect(n.default == 1.5)
        } else { Issue.record("scale_factor should be .number") }
        if case .luaLiteral = byKey["custom_table"] {} else {
            Issue.record("custom_table should be .luaLiteral")
        }
        if case .luaLiteral = byKey["undocumented"] {} else {
            Issue.record("undocumented should be .luaLiteral")
        }
    }
}
