import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("Hotkey helpers")
struct HotkeyTests {

    // MARK: - keyName

    @Test
    func keyNameForKnownSpecialKeys() {
        // A representative slice of the special-key table. Full
        // coverage of all keyCodes would just re-test the table.
        #expect(Hotkey.keyName(forKeyCode: 36)  == "return")
        #expect(Hotkey.keyName(forKeyCode: 49)  == "space")
        #expect(Hotkey.keyName(forKeyCode: 53)  == "escape")
        #expect(Hotkey.keyName(forKeyCode: 51)  == "delete")
        #expect(Hotkey.keyName(forKeyCode: 123) == "left")
        #expect(Hotkey.keyName(forKeyCode: 124) == "right")
        #expect(Hotkey.keyName(forKeyCode: 125) == "down")
        #expect(Hotkey.keyName(forKeyCode: 126) == "up")
        #expect(Hotkey.keyName(forKeyCode: 122) == "f1")
        #expect(Hotkey.keyName(forKeyCode: 111) == "f12")
    }

    @Test
    func keyNameReturnsNilForLetterKeys() {
        // Letters resolve via NSEvent.charactersIgnoringModifiers on the
        // AppKit side — Kit deliberately doesn't try to handle them.
        // 0 = "a", 1 = "s", 2 = "d"... all unknown to the table.
        #expect(Hotkey.keyName(forKeyCode: 0) == nil)
        #expect(Hotkey.keyName(forKeyCode: 1) == nil)
        #expect(Hotkey.keyName(forKeyCode: 6) == nil)   // z
    }

    // MARK: - mod glyphs

    @Test
    func modGlyphMapsKnownModifiers() {
        #expect(Hotkey.modGlyph("cmd")   == "⌘")
        #expect(Hotkey.modGlyph("alt")   == "⌥")
        #expect(Hotkey.modGlyph("ctrl")  == "⌃")
        #expect(Hotkey.modGlyph("shift") == "⇧")
    }

    @Test
    func modGlyphPassesUnknownThrough() {
        // A future Mac with a "hyper" key, or somebody's custom name,
        // shouldn't vanish from the UI.
        #expect(Hotkey.modGlyph("hyper") == "hyper")
        #expect(Hotkey.modGlyph("fn")    == "fn")
    }

    // MARK: - sortedMods (display order)

    @Test
    func sortedModsMatchesMenuBarConvention() {
        // Apple's menu-bar order is ctrl, alt, shift, cmd (left-to-right).
        // Any input permutation should normalise to that order.
        #expect(Hotkey.sortedMods(["cmd", "ctrl"]) == ["ctrl", "cmd"])
        #expect(Hotkey.sortedMods(["shift", "ctrl", "cmd"])
                == ["ctrl", "shift", "cmd"])
        #expect(Hotkey.sortedMods(["alt", "shift", "ctrl", "cmd"])
                == ["ctrl", "alt", "shift", "cmd"])
    }

    @Test
    func sortedModsKeepsUnknownAtEndPreservingOrder() {
        // Unknown modifiers are appended in input order so the user can
        // at least see them — but the known mods still come first in
        // canonical order.
        let result = Hotkey.sortedMods(["fn", "cmd", "hyper", "ctrl"])
        #expect(result == ["ctrl", "cmd", "fn", "hyper"])
    }

    // MARK: - formatBinding (full display)

    @Test
    func formatBindingForCommonChords() {
        // Mods sorted, key uppercased, glyphs concatenated with no
        // separator (matches macOS conventions).
        #expect(Hotkey.formatBinding(
            HotkeyBinding(mods: ["ctrl", "cmd"], key: "f")) == "⌃⌘F")
        #expect(Hotkey.formatBinding(
            HotkeyBinding(mods: ["cmd", "alt"], key: "k")) == "⌥⌘K")
        #expect(Hotkey.formatBinding(
            HotkeyBinding(mods: ["shift", "ctrl"], key: "left"))
                == "⌃⇧←")
        #expect(Hotkey.formatBinding(
            HotkeyBinding(mods: ["shift", "ctrl", "cmd"], key: "m"))
                == "⌃⇧⌘M")
    }

    @Test
    func formatBindingForNoModifierKey() {
        // Edge case: single-key binding (rare but valid).
        #expect(Hotkey.formatBinding(
            HotkeyBinding(mods: [], key: "escape")) == "⎋")
        #expect(Hotkey.formatBinding(
            HotkeyBinding(mods: [], key: "f1")) == "F1")
    }

    @Test
    func formatBindingForNonModifierFunctionKeys() {
        // Function keys are uppercased so "f1" → "F1" rather than the
        // lowercase Lua-side name.
        #expect(Hotkey.formatBinding(
            HotkeyBinding(mods: ["cmd"], key: "f12")) == "⌘F12")
    }

    // MARK: - HotkeyAction.defaults

    @Test
    func defaultsExtractsBindingsFromActions() {
        let actions = try! JSONDecoder().decode(
            [HotkeyAction].self, from: Data("""
            [
              {"action":"toggle", "default":{"mods":["cmd"],"key":"f"}},
              {"action":"next",   "default":{"mods":["shift","cmd"],"key":"n"}}
            ]
            """.utf8))
        let defaults = HotkeyAction.defaults(from: actions)
        #expect(defaults.count == 2)
        #expect(defaults["toggle"] == HotkeyBinding(mods: ["cmd"], key: "f"))
        #expect(defaults["next"]   == HotkeyBinding(
            mods: ["shift", "cmd"], key: "n"))
    }

    @Test
    func defaultsSkipsActionsWithoutADefault() {
        // The install→auto-activate flow shouldn't invent bindings
        // the maintainer didn't pick. Actions without a `default` drop
        // out so SpoonInstall doesn't bind something unexpected.
        let actions = try! JSONDecoder().decode(
            [HotkeyAction].self, from: Data("""
            [
              {"action":"toggle", "default":{"mods":["cmd"],"key":"f"}},
              {"action":"reset",  "label":"Reset"}
            ]
            """.utf8))
        let defaults = HotkeyAction.defaults(from: actions)
        #expect(defaults.count == 1)
        #expect(defaults["toggle"] != nil)
        #expect(defaults["reset"]  == nil)
    }

    @Test
    func defaultsOnEmptyInputReturnsEmpty() {
        #expect(HotkeyAction.defaults(from: []).isEmpty)
    }
}
