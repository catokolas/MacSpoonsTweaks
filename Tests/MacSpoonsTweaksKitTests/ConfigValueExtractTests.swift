import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("ConfigValue extractors")
struct ConfigValueExtractTests {

    // MARK: - Strict cases

    @Test
    func boolExtractsOnlyFromBoolCase() {
        #expect(ConfigValue.bool(true).asBool == true)
        #expect(ConfigValue.bool(false).asBool == false)
        #expect(ConfigValue.int(1).asBool == nil)
        #expect(ConfigValue.string("true").asBool == nil)
        #expect(ConfigValue.null.asBool == nil)
    }

    @Test
    func stringExtractsOnlyFromStringCase() {
        #expect(ConfigValue.string("hello").asString == "hello")
        #expect(ConfigValue.string("").asString == "")
        #expect(ConfigValue.int(42).asString == nil)
        // Lua literal stays distinct from a plain string — neither
        // direction crosses over.
        #expect(ConfigValue.luaLiteral("\"hello\"").asString == nil)
    }

    @Test
    func stringListExtractsOnlyFromStringListCase() {
        #expect(ConfigValue.stringList(["a", "b"]).asStringList == ["a", "b"])
        #expect(ConfigValue.stringList([]).asStringList == [])
        #expect(ConfigValue.object([:]).asStringList == nil)
    }

    @Test
    func objectExtractsOnlyFromObjectCase() {
        let d: [String: ConfigValue] = ["k": .bool(true)]
        #expect(ConfigValue.object(d).asObject == d)
        #expect(ConfigValue.object([:]).asObject == [:])
        #expect(ConfigValue.bool(true).asObject == nil)
    }

    @Test
    func luaLiteralExtractsOnlyFromLuaLiteralCase() {
        #expect(ConfigValue.luaLiteral("{1,2}").asLuaLiteral == "{1,2}")
        #expect(ConfigValue.string("{1,2}").asLuaLiteral == nil)
    }

    // MARK: - Numeric cross-type rules

    @Test
    func intExtractsFromIntDirectly() {
        #expect(ConfigValue.int(42).asInt == 42)
        #expect(ConfigValue.int(-7).asInt == -7)
        #expect(ConfigValue.int(0).asInt == 0)
    }

    @Test
    func intAllowsLosslessPromotionFromIntegralDouble() {
        // .number(5.0) → 5: the value has no fractional component, so
        // there's nothing to lose. This matches the manifest pattern of
        // storing int-typed fields as `.int(5)` but allowing UI input
        // through a Double-backed Slider to still round-trip cleanly.
        #expect(ConfigValue.number(5.0).asInt == 5)
        #expect(ConfigValue.number(-3.0).asInt == -3)
        #expect(ConfigValue.number(0.0).asInt == 0)
    }

    @Test
    func intRejectsDoubleWithFractionalComponent() {
        // .number(5.5) → nil: silently rounding would lose the user's
        // input. The form layer falls back to the manifest default in
        // this case.
        #expect(ConfigValue.number(5.5).asInt == nil)
        #expect(ConfigValue.number(0.1).asInt == nil)
        #expect(ConfigValue.number(-0.001).asInt == nil)
    }

    @Test
    func intRejectsOutOfRangeDouble() {
        // Larger than Int.max — must not crash with overflow.
        #expect(ConfigValue.number(1e30).asInt == nil)
        #expect(ConfigValue.number(-1e30).asInt == nil)
    }

    @Test
    func doubleExtractsFromNumberDirectly() {
        #expect(ConfigValue.number(0.1).asDouble == 0.1)
        #expect(ConfigValue.number(-3.5).asDouble == -3.5)
        #expect(ConfigValue.number(0.0).asDouble == 0.0)
    }

    @Test
    func doubleLosslessPromotesFromInt() {
        // The reverse direction is always safe — Int fits in Double for
        // values up to 2^53.
        #expect(ConfigValue.int(42).asDouble == 42.0)
        #expect(ConfigValue.int(-7).asDouble == -7.0)
        #expect(ConfigValue.int(0).asDouble == 0.0)
    }

    @Test
    func numericExtractorsRejectNonNumericValues() {
        #expect(ConfigValue.bool(true).asInt == nil)
        #expect(ConfigValue.string("42").asInt == nil)
        #expect(ConfigValue.stringList([]).asDouble == nil)
        #expect(ConfigValue.object([:]).asDouble == nil)
        #expect(ConfigValue.null.asInt == nil)
        #expect(ConfigValue.null.asDouble == nil)
    }
}
