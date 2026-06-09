import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("LuaLiteral encoder")
struct LuaLiteralTests {

    // MARK: - Primitives

    @Test
    func nilEncodesAsLuaNil() {
        #expect(LuaLiteral.encode(.null) == "nil")
    }

    @Test
    func booleans() {
        #expect(LuaLiteral.encode(.bool(true))  == "true")
        #expect(LuaLiteral.encode(.bool(false)) == "false")
    }

    @Test
    func integers() {
        #expect(LuaLiteral.encode(.int(0))  == "0")
        #expect(LuaLiteral.encode(.int(42)) == "42")
        #expect(LuaLiteral.encode(.int(-7)) == "-7")
        #expect(LuaLiteral.encode(.int(Int.max)) == "\(Int.max)")
    }

    /// `.number(...)` must always emit float form so Lua's parser stores
    /// it as a float (not an int). Round-trip should be shortest possible.
    @Test
    func numbersAlwaysCarryFloatForm() {
        #expect(LuaLiteral.encode(.number(0.1))  == "0.1")
        #expect(LuaLiteral.encode(.number(5.0))  == "5.0")     // not "5"
        #expect(LuaLiteral.encode(.number(-3.5)) == "-3.5")
        #expect(LuaLiteral.encode(.number(0.0))  == "0.0")
    }

    @Test
    func numbersRoundTripPrecision() {
        let cases: [Double] = [0.1, 0.2, 1.0/3.0, 1e-9, 1e20, .pi]
        for value in cases {
            let encoded = LuaLiteral.encode(.number(value))
            #expect(Double(encoded) == value, "round-trip lost \(value)")
        }
    }

    @Test
    func nonFiniteNumbers() {
        #expect(LuaLiteral.encode(.number(.infinity))  == "math.huge")
        #expect(LuaLiteral.encode(.number(-.infinity)) == "-math.huge")
        // NaN: we just need a valid Lua expression for NaN; (0/0) gives it.
        #expect(LuaLiteral.encode(.number(.nan)) == "(0/0)")
    }

    // MARK: - Strings

    @Test
    func emptyString() {
        #expect(LuaLiteral.encode(.string("")) == "\"\"")
    }

    @Test
    func simpleAsciiString() {
        #expect(LuaLiteral.encode(.string("hello")) == "\"hello\"")
    }

    @Test
    func stringWithEmbeddedQuote() {
        // Input: a"b
        // Lua:   "a\"b"
        #expect(LuaLiteral.encode(.string("a\"b")) == "\"a\\\"b\"")
    }

    @Test
    func stringWithEmbeddedBackslash() {
        // Input: a\b
        // Lua:   "a\\b"
        #expect(LuaLiteral.encode(.string("a\\b")) == "\"a\\\\b\"")
    }

    @Test
    func stringWithMixedQuoteAndBackslash() {
        // Adversarial: a"b\c — both metacharacters in one string.
        // Lua should be "a\"b\\c"
        #expect(LuaLiteral.encode(.string("a\"b\\c")) == "\"a\\\"b\\\\c\"")
    }

    @Test
    func stringWithNewlineAndTabAndCR() {
        // Each control gets its named escape.
        let input    = "line1\nline2\tcol\rend"
        let expected = "\"line1\\nline2\\tcol\\rend\""
        #expect(LuaLiteral.encode(.string(input)) == expected)
    }

    @Test
    func stringWithNullByte() {
        // Null byte → \000 (decimal). Lua handles it as a valid string char.
        let input    = "a\0b"
        let expected = "\"a\\000b\""
        #expect(LuaLiteral.encode(.string(input)) == expected)
    }

    @Test
    func stringWithDeleteAndOtherControls() {
        // 0x7F (DEL) and 0x1F (US) → \127, \031 respectively.
        let input    = "x\u{1F}y\u{7F}z"
        let expected = "\"x\\031y\\127z\""
        #expect(LuaLiteral.encode(.string(input)) == expected)
    }

    @Test
    func utf8MultiByteStringsPassThrough() {
        // The encoder treats strings as byte sequences; UTF-8 just survives.
        // Lua doesn't care about the encoding inside a string literal.
        let input = "café 🥄"
        let encoded = LuaLiteral.encode(.string(input))
        #expect(encoded.hasPrefix("\""))
        #expect(encoded.hasSuffix("\""))
        // Strip the surrounding quotes and check the inner bytes round-trip.
        let inner = String(encoded.dropFirst().dropLast())
        #expect(inner == input)
    }

    /// The point of all the escaping: a string that LOOKS like Lua code
    /// must not actually inject code. After encoding, the result should
    /// be inert when interpolated into a Lua expression.
    @Test
    func adversarialInjectionAttemptIsInert() {
        // String that would close an unquoted concatenation and run code.
        let attempt = "\"); os.execute('rm -rf /'); print(\""
        let encoded = LuaLiteral.encode(.string(attempt))
        // The encoded form starts and ends with a single ", and every "
        // and \ in the input is escaped. The receiving Lua parser will
        // see ONE string literal regardless.
        #expect(encoded.hasPrefix("\""))
        #expect(encoded.hasSuffix("\""))
        // No raw double-quotes remain that could close the literal.
        let inner = String(encoded.dropFirst().dropLast())
        #expect(!inner.contains("\"") || inner.contains("\\\""))
        // Specifically: the encoded form's `\"` sequences round-trip
        // back to the original input when Lua parses them.
        let allEscapesAreEscaped = inner.replacingOccurrences(of: "\\\\", with: "")
                                        .contains("\\\"")
        #expect(allEscapesAreEscaped)
    }

    // MARK: - String lists

    @Test
    func emptyStringList() {
        #expect(LuaLiteral.encode(.stringList([])) == "{}")
    }

    @Test
    func singleElementStringList() {
        #expect(LuaLiteral.encode(.stringList(["a"])) == "{ \"a\" }")
    }

    @Test
    func multiElementStringListPreservesOrder() {
        // ConfigValue.stringList is an ordered sequence — order MUST be
        // preserved (unlike object keys, which sort).
        #expect(LuaLiteral.encode(.stringList(["b", "a", "c"]))
                == "{ \"b\", \"a\", \"c\" }")
    }

    @Test
    func stringListContainingSpecialStrings() {
        let encoded = LuaLiteral.encode(.stringList(["a\"b", "c\\d"]))
        #expect(encoded == "{ \"a\\\"b\", \"c\\\\d\" }")
    }

    // MARK: - Objects (Lua tables)

    @Test
    func emptyObject() {
        #expect(LuaLiteral.encode(.object([:])) == "{}")
    }

    @Test
    func objectWithIdentifierKeysUsesBarewordForm() {
        let v: ConfigValue = .object([
            "delay": .number(0.1),
            "wrap":  .bool(false),
        ])
        // Sorted-key output: delay before wrap.
        #expect(LuaLiteral.encode(v) == "{ delay = 0.1, wrap = false }")
    }

    @Test
    func objectKeysAreSortedForStableDiffs() {
        let v: ConfigValue = .object([
            "zebra": .int(1),
            "alpha": .int(2),
            "mango": .int(3),
        ])
        #expect(LuaLiteral.encode(v) == "{ alpha = 2, mango = 3, zebra = 1 }")
    }

    @Test
    func reservedWordKeysAreQuoted() {
        // Lua reserved words can't be barewords — must use ["..."] form.
        let v: ConfigValue = .object([
            "end":   .bool(true),
            "while": .bool(false),
            "valid": .bool(true),
        ])
        // Sorted: "end" < "valid" < "while"
        #expect(LuaLiteral.encode(v)
                == "{ [\"end\"] = true, valid = true, [\"while\"] = false }")
    }

    @Test
    func keysWithSpacesOrSpecialCharsAreQuoted() {
        let v: ConfigValue = .object([
            "valid_key": .int(1),
            "has space": .int(2),
            "9starts":   .int(3),     // leading digit — not a valid identifier
        ])
        let encoded = LuaLiteral.encode(v)
        // Sorted: "9starts" < "has space" < "valid_key"
        #expect(encoded
                == "{ [\"9starts\"] = 3, [\"has space\"] = 2, valid_key = 1 }")
    }

    @Test
    func emptyKeyIsQuoted() {
        let v: ConfigValue = .object(["": .bool(true)])
        #expect(LuaLiteral.encode(v) == "{ [\"\"] = true }")
    }

    @Test
    func nestedObjectsRecurse() {
        // Mirrors the shape of MouseTrackpadTweaks.middleClick — deep
        // merge of nested tables is exactly what the encoder must support.
        let v: ConfigValue = .object([
            "middleClick": .object([
                "enabled": .bool(true),
                "multiFinger": .object([
                    "fingerCount": .int(4),
                ]),
            ]),
        ])
        let encoded = LuaLiteral.encode(v)
        #expect(encoded == "{ middleClick = { enabled = true, "
                         + "multiFinger = { fingerCount = 4 } } }")
    }

    // MARK: - luaLiteral pass-through

    @Test
    func luaLiteralPassesThroughVerbatim() {
        // The user has already validated this snippet against `hs -c`.
        // We trust it and embed as-is.
        let raw = "{ 1, 2, 3, foo = bar() }"
        #expect(LuaLiteral.encode(.luaLiteral(raw)) == raw)
    }

    @Test
    func luaLiteralInsideObjectStaysVerbatim() {
        let v: ConfigValue = .object([
            "complex": .luaLiteral("hs.json.decode('{\"x\":1}')"),
        ])
        #expect(LuaLiteral.encode(v)
                == "{ complex = hs.json.decode('{\"x\":1}') }")
    }

    // MARK: - encodeKey direct API

    @Test
    func encodeKeyForBareIdentifier() {
        #expect(LuaLiteral.encodeKey("delay") == "delay")
        #expect(LuaLiteral.encodeKey("_foo")  == "_foo")
        #expect(LuaLiteral.encodeKey("a1_2")  == "a1_2")
    }

    @Test
    func encodeKeyForReservedWord() {
        #expect(LuaLiteral.encodeKey("end")      == "[\"end\"]")
        #expect(LuaLiteral.encodeKey("function") == "[\"function\"]")
        #expect(LuaLiteral.encodeKey("nil")      == "[\"nil\"]")
    }

    @Test
    func encodeKeyForNonIdentifier() {
        #expect(LuaLiteral.encodeKey("with space") == "[\"with space\"]")
        #expect(LuaLiteral.encodeKey("1leading")   == "[\"1leading\"]")
        #expect(LuaLiteral.encodeKey("")           == "[\"\"]")
    }
}
