import Foundation

/// Helpers for capturing and rendering hotkey bindings. Pure — the
/// AppKit-side recorder feeds in a virtual keyCode + a modifier set,
/// and these functions hand back the Hammerspoon name and a glyph
/// representation for display.
public enum Hotkey {

    // MARK: - keyCode → Hammerspoon name

    /// Returns the Hammerspoon name for a special key (arrows, function
    /// keys, escape, return, etc.), or `nil` for printable keys.
    /// Printable keys should be resolved from
    /// `NSEvent.charactersIgnoringModifiers` on the AppKit side — that
    /// path correctly handles layout-sensitive characters that don't
    /// have a fixed virtual keyCode (e.g. "/" vs "\\" on AZERTY).
    public static func keyName(forKeyCode keyCode: Int) -> String? {
        return specialKeyTable[keyCode]
    }

    /// Canonical macOS virtual keyCodes for the special-purpose keys.
    /// Reference: `<Carbon/HIToolbox/Events.h>`. Names match
    /// Hammerspoon's `hs.hotkey` table.
    private static let specialKeyTable: [Int: String] = [
        36:  "return",
        76:  "padenter",
        48:  "tab",
        49:  "space",
        51:  "delete",
        117: "forwarddelete",
        53:  "escape",
        // Arrow cluster.
        123: "left",
        124: "right",
        125: "down",
        126: "up",
        // Editing cluster.
        115: "home",
        119: "end",
        116: "pageup",
        121: "pagedown",
        // Function row.
        122: "f1",
        120: "f2",
        99:  "f3",
        118: "f4",
        96:  "f5",
        97:  "f6",
        98:  "f7",
        100: "f8",
        101: "f9",
        109: "f10",
        103: "f11",
        111: "f12",
        105: "f13",
        107: "f14",
        113: "f15",
        // Volume / brightness row would go here, but those are usually
        // consumed by the system and never reach event taps.
    ]

    // MARK: - Modifier glyphs

    /// `cmd` → `⌘`, `alt` → `⌥`, `ctrl` → `⌃`, `shift` → `⇧`. Anything
    /// else passes through unchanged so unknown mods are at least
    /// visible.
    public static func modGlyph(_ mod: String) -> String {
        switch mod {
        case "cmd":   return "⌘"
        case "alt":   return "⌥"
        case "ctrl":  return "⌃"
        case "shift": return "⇧"
        default:      return mod
        }
    }

    /// Canonical mod display order — matches Apple's menu-bar
    /// convention so the user sees the same chord shape they'd see in
    /// macOS menus.
    public static let modDisplayOrder = ["ctrl", "alt", "shift", "cmd"]

    /// Sort a list of mods into display order, dropping anything we
    /// don't know about (preserves their original order at the end).
    public static func sortedMods(_ mods: [String]) -> [String] {
        var known: [String] = []
        var unknown: [String] = []
        for mod in mods {
            if modDisplayOrder.contains(mod) { known.append(mod) }
            else                              { unknown.append(mod) }
        }
        known.sort { (a, b) in
            modDisplayOrder.firstIndex(of: a)!
                < modDisplayOrder.firstIndex(of: b)!
        }
        return known + unknown
    }

    /// Single-line display string for a binding — modifier glyphs
    /// followed by the key, e.g. `⌃⌘F` or `⇧⌃→`. Single-character keys
    /// are uppercased so they read as keycap glyphs; multi-character
    /// names (arrows, return, …) get their own glyph mapping.
    public static func formatBinding(_ binding: HotkeyBinding) -> String {
        let mods = sortedMods(binding.mods).map(modGlyph).joined()
        let key  = keyDisplay(binding.key)
        return mods + key
    }

    /// Special keys we know how to render as glyphs; anything else
    /// renders as the key name uppercased (e.g. `F`).
    private static let keyGlyphs: [String: String] = [
        "left":          "←",
        "right":         "→",
        "up":            "↑",
        "down":          "↓",
        "return":        "↵",
        "padenter":      "⌤",
        "tab":           "⇥",
        "space":         "␣",
        "escape":        "⎋",
        "delete":        "⌫",
        "forwarddelete": "⌦",
        "home":          "↖",
        "end":           "↘",
        "pageup":        "⇞",
        "pagedown":      "⇟",
    ]

    private static func keyDisplay(_ key: String) -> String {
        if let glyph = keyGlyphs[key] { return glyph }
        if key.count == 1 { return key.uppercased() }
        // Function keys etc. — uppercased keeps F1..F12 looking right.
        return key.uppercased()
    }
}
