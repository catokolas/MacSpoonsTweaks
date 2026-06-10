import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("HammerspoonScript builders")
struct HammerspoonScriptTests {

    // MARK: - Lifecycle one-liners

    @Test
    func loadSpoon() {
        // Guarded so we don't re-execute init.lua and wipe a Spoon
        // instance that's already loaded and holding event-tap state.
        #expect(HammerspoonScript.loadSpoon("FocusFollowsMouse")
                == "if not spoon.FocusFollowsMouse then "
                + "hs.loadSpoon(\"FocusFollowsMouse\") end")
    }

    @Test
    func startStopReload() {
        #expect(HammerspoonScript.startSpoon("FocusFollowsMouse")
                == "spoon.FocusFollowsMouse:start()")
        #expect(HammerspoonScript.stopSpoon("FocusFollowsMouse")
                == "spoon.FocusFollowsMouse:stop()")
        #expect(HammerspoonScript.reload() == "hs.reload()")
    }

    // MARK: - configure (:configure path)

    @Test
    func configureWithConfigureSpoonUsesMethodCall() {
        let cfg: ConfigValue = .object([
            "delay": .number(0.05),
            "excludedApps": .stringList(["Notification Center"]),
        ])
        let script = HammerspoonScript.configure(
            spoon: "FocusFollowsMouse", config: cfg, hasConfigure: true)
        #expect(script ==
            "spoon.FocusFollowsMouse:configure(" +
            "{ delay = 0.05, excludedApps = { \"Notification Center\" } })")
    }

    @Test
    func configureWithConfigureSupportsDeepNesting() {
        // Matches the deep-merge shape of MouseTrackpadTweaks.middleClick:
        // partial overrides leave sibling keys untouched on the receiving
        // side. The script just emits the partial; the merge is the
        // Spoon's :configure responsibility.
        let cfg: ConfigValue = .object([
            "middleClick": .object([
                "multiFinger": .object([
                    "fingerCount": .int(4),
                ]),
            ]),
        ])
        let script = HammerspoonScript.configure(
            spoon: "MouseTrackpadTweaks", config: cfg, hasConfigure: true)
        #expect(script ==
            "spoon.MouseTrackpadTweaks:configure(" +
            "{ middleClick = { multiFinger = { fingerCount = 4 } } })")
    }

    @Test
    func configureEmptyObjectProducesEmptyScript() {
        let cfg: ConfigValue = .object([:])
        // No-op script — caller can blindly concatenate it.
        #expect(HammerspoonScript.configure(
            spoon: "X", config: cfg, hasConfigure: true) == "")
        #expect(HammerspoonScript.configure(
            spoon: "X", config: cfg, hasConfigure: false) == "")
    }

    @Test
    func configureNonObjectProducesEmptyScript() {
        // Programming error on the caller's side, but stay defensive.
        #expect(HammerspoonScript.configure(
            spoon: "X", config: .bool(true), hasConfigure: true) == "")
    }

    // MARK: - configure (per-field assignment path)

    @Test
    func configureWithoutConfigureEmitsPerFieldAssignments() {
        // Caffeine (upstream) has no :configure; expects flat
        // `spoon.X.field = value` assignments.
        let cfg: ConfigValue = .object([
            "show_notifications": .bool(true),
            "timeout_seconds":    .int(3600),
        ])
        let script = HammerspoonScript.configure(
            spoon: "Caffeine", config: cfg, hasConfigure: false)
        // Sorted-key order: show_notifications < timeout_seconds.
        #expect(script ==
            "spoon.Caffeine.show_notifications = true\n" +
            "spoon.Caffeine.timeout_seconds = 3600")
    }

    @Test
    func configureWithoutConfigureKeysSortedDeterministically() {
        let cfg: ConfigValue = .object([
            "zebra": .int(1),
            "alpha": .int(2),
        ])
        let script = HammerspoonScript.configure(
            spoon: "X", config: cfg, hasConfigure: false)
        #expect(script == "spoon.X.alpha = 2\nspoon.X.zebra = 1")
    }

    @Test
    func configureWithoutConfigureUsesBracketFormForReservedKeys() {
        let cfg: ConfigValue = .object([
            "end": .bool(true),       // reserved word
        ])
        let script = HammerspoonScript.configure(
            spoon: "X", config: cfg, hasConfigure: false)
        #expect(script == "spoon.X[\"end\"] = true")
    }

    // MARK: - bindHotkeys

    @Test
    func bindHotkeysSingleAction() {
        let mapping = ["toggle": HotkeyBinding(mods: ["ctrl", "cmd"], key: "f")]
        let script = HammerspoonScript.bindHotkeys(
            spoon: "FocusFollowsMouse", mapping: mapping)
        #expect(script ==
            "spoon.FocusFollowsMouse:bindHotkeys(" +
            "{ toggle = { { \"ctrl\", \"cmd\" }, \"f\" } })")
    }

    @Test
    func bindHotkeysMultiActionSortedAlphabetically() {
        // MouseTrackpadTweaks has three actions; sorted output for diff
        // stability.
        let mapping: [String: HotkeyBinding] = [
            "toggleMiddleClick":  HotkeyBinding(mods: ["ctrl","cmd"],         key: "k"),
            "toggle":             HotkeyBinding(mods: ["shift","ctrl","cmd"], key: "m"),
            "toggleInvertScroll": HotkeyBinding(mods: ["ctrl","cmd"],         key: "i"),
        ]
        let script = HammerspoonScript.bindHotkeys(
            spoon: "MouseTrackpadTweaks", mapping: mapping)
        #expect(script ==
            "spoon.MouseTrackpadTweaks:bindHotkeys({ " +
            "toggle = { { \"shift\", \"ctrl\", \"cmd\" }, \"m\" }, " +
            "toggleInvertScroll = { { \"ctrl\", \"cmd\" }, \"i\" }, " +
            "toggleMiddleClick = { { \"ctrl\", \"cmd\" }, \"k\" } })")
    }

    @Test
    func bindHotkeysEmptyMappingProducesEmptyScript() {
        #expect(HammerspoonScript.bindHotkeys(spoon: "X", mapping: [:]) == "")
    }

    @Test
    func bindHotkeysWithSpecialKeyChars() {
        // The "key" half may be a non-ASCII or special-symbol name —
        // shouldn't escape badly.
        let mapping = ["toggle": HotkeyBinding(mods: ["ctrl"], key: "[")]
        let script = HammerspoonScript.bindHotkeys(
            spoon: "X", mapping: mapping)
        #expect(script ==
            "spoon.X:bindHotkeys({ toggle = { { \"ctrl\" }, \"[\" } })")
    }

    // MARK: - readProperty

    @Test
    func readPropertySimple() {
        #expect(HammerspoonScript.readProperty(
                    spoon: "FocusFollowsMouse", fieldPath: "delay")
                == "return spoon.FocusFollowsMouse.delay")
    }

    @Test
    func readPropertyDeeplyNested() {
        // Matches the verification step: deep-merge proof reads back
        // middleClick.multiFinger.fingerCount.
        #expect(HammerspoonScript.readProperty(
                    spoon: "MouseTrackpadTweaks",
                    fieldPath: "middleClick.multiFinger.fingerCount")
                == "return spoon.MouseTrackpadTweaks.middleClick" +
                   ".multiFinger.fingerCount")
    }
}
