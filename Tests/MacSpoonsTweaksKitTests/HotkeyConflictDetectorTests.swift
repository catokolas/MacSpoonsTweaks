import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("HotkeyConflictDetector")
struct HotkeyConflictDetectorTests {

    @Test
    func noConflictsWhenAllBindingsUnique() {
        let snapshot = [
            "FocusFollowsMouse": [
                "toggle": HotkeyBinding(mods: ["ctrl","cmd"], key: "f"),
            ],
            "MouseScrollTweaks": [
                "toggle": HotkeyBinding(mods: ["ctrl","cmd"], key: "m"),
            ],
        ]
        #expect(HotkeyConflictDetector.findConflicts(across: snapshot).isEmpty)
    }

    @Test
    func detectsConflictAcrossSpoons() {
        let snapshot = [
            "FocusFollowsMouse": [
                "toggle": HotkeyBinding(mods: ["ctrl","cmd"], key: "f"),
            ],
            "MouseScrollTweaks": [
                "toggle": HotkeyBinding(mods: ["ctrl","cmd"], key: "f"),
            ],
        ]
        let conflicts = HotkeyConflictDetector.findConflicts(across: snapshot)
        #expect(conflicts.count == 1)
        let c = conflicts[0]
        #expect(c.binding.key == "f")
        #expect(Set(c.binding.mods) == ["ctrl", "cmd"])
        #expect(c.participants.count == 2)
        #expect(c.participants.contains(.init(
            spoonName: "FocusFollowsMouse", actionName: "toggle")))
        #expect(c.participants.contains(.init(
            spoonName: "MouseScrollTweaks", actionName: "toggle")))
    }

    @Test
    func detectsConflictWithinSingleSpoon() {
        // User accidentally binds two actions of the same Spoon to the
        // same chord. Should still flag — Hammerspoon would silently
        // pick the second.
        let snapshot = [
            "MouseTrackpadTweaks": [
                "toggle":             HotkeyBinding(
                    mods: ["ctrl","cmd"], key: "k"),
                "toggleMiddleClick":  HotkeyBinding(
                    mods: ["ctrl","cmd"], key: "k"),
            ]
        ]
        let conflicts = HotkeyConflictDetector.findConflicts(across: snapshot)
        #expect(conflicts.count == 1)
        #expect(conflicts[0].participants.count == 2)
    }

    @Test
    func modifierOrderingDoesNotHidConflicts() {
        let snapshot = [
            "A": ["toggle": HotkeyBinding(
                mods: ["cmd","ctrl"], key: "f")],
            "B": ["toggle": HotkeyBinding(
                mods: ["ctrl","cmd"], key: "f")],
        ]
        let conflicts = HotkeyConflictDetector.findConflicts(across: snapshot)
        #expect(conflicts.count == 1,
                "different mod orderings of the same chord should register as a conflict")
    }

    @Test
    func caseDifferenceInKeyDoesNotHideConflicts() {
        // Hammerspoon treats "F" and "f" as the same key; the detector
        // should too. (NSEvent.charactersIgnoringModifiers gives the
        // unshifted character so this is mostly defensive against
        // manually-edited state.json.)
        let snapshot = [
            "A": ["toggle": HotkeyBinding(mods: ["ctrl"], key: "F")],
            "B": ["toggle": HotkeyBinding(mods: ["ctrl"], key: "f")],
        ]
        #expect(HotkeyConflictDetector.findConflicts(
            across: snapshot).count == 1)
    }

    @Test
    func detectsThreeOrMoreParticipants() {
        let snapshot = [
            "A": ["toggle": HotkeyBinding(mods: ["ctrl"], key: "x")],
            "B": ["toggle": HotkeyBinding(mods: ["ctrl"], key: "x")],
            "C": ["toggle": HotkeyBinding(mods: ["ctrl"], key: "x")],
        ]
        let conflicts = HotkeyConflictDetector.findConflicts(
            across: snapshot)
        #expect(conflicts.count == 1)
        #expect(conflicts[0].participants.count == 3)
    }

    @Test
    func isInConflictAnswersForSpecificParticipant() {
        let conflicts = HotkeyConflictDetector.findConflicts(across: [
            "A": ["toggle": HotkeyBinding(mods: ["ctrl"], key: "x")],
            "B": ["toggle": HotkeyBinding(mods: ["ctrl"], key: "x")],
            "C": ["toggle": HotkeyBinding(mods: ["ctrl"], key: "y")],
        ])
        #expect(HotkeyConflictDetector.isInConflict(
            participant: .init(spoonName: "A", actionName: "toggle"),
            conflicts: conflicts))
        #expect(HotkeyConflictDetector.isInConflict(
            participant: .init(spoonName: "B", actionName: "toggle"),
            conflicts: conflicts))
        // C is unique — not in any conflict.
        #expect(!HotkeyConflictDetector.isInConflict(
            participant: .init(spoonName: "C", actionName: "toggle"),
            conflicts: conflicts))
    }

    @Test
    func participantOrderingIsStableAcrossRuns() {
        // The participants list within a conflict is built by
        // iterating spoons sorted-by-name then actions sorted-by-name.
        // Same input must yield the same output every call.
        let snapshot = [
            "Zebra":  ["toggle": HotkeyBinding(
                mods: ["ctrl"], key: "p")],
            "Alpha":  ["toggle": HotkeyBinding(
                mods: ["ctrl"], key: "p")],
        ]
        let c1 = HotkeyConflictDetector.findConflicts(across: snapshot)
        let c2 = HotkeyConflictDetector.findConflicts(across: snapshot)
        #expect(c1 == c2)
        // Alpha < Zebra → Alpha participates first.
        #expect(c1[0].participants.first?.spoonName == "Alpha")
    }
}
