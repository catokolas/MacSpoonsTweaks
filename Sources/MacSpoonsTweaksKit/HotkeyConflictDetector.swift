import Foundation

/// One group of hotkey bindings sharing the same chord. Returned by
/// `HotkeyConflictDetector.findConflicts`.
public struct HotkeyConflict: Equatable, Sendable {
    /// The conflicting chord — mods in canonical (sorted) order, key
    /// lowercased. Suitable for display via `Hotkey.formatBinding`.
    public let binding: HotkeyBinding
    /// The 2+ participants that all bind this chord. Listed in the
    /// order they appeared in the input map; ties broken by sort.
    public let participants: [Participant]

    public struct Participant: Equatable, Hashable, Sendable {
        public let spoonName: String
        public let actionName: String
        public init(spoonName: String, actionName: String) {
            self.spoonName = spoonName
            self.actionName = actionName
        }
    }

    public init(binding: HotkeyBinding, participants: [Participant]) {
        self.binding = binding
        self.participants = participants
    }
}

public enum HotkeyConflictDetector {

    /// Detect conflicts across a snapshot of every Spoon's effective
    /// hotkey bindings.
    ///
    /// Two bindings conflict iff they share the same chord under a
    /// canonical comparison: modifiers compared as a SET (so
    /// `["cmd","ctrl"]` and `["ctrl","cmd"]` match), key lowercased
    /// (so `"F"` and `"f"` match).
    ///
    /// Returns one `HotkeyConflict` per chord that has 2+ participants.
    /// The list itself is sorted by chord for stable output.
    public static func findConflicts(
        across spoons: [String: [String: HotkeyBinding]]
    ) -> [HotkeyConflict] {
        // Build canonical-chord → [participants] map.
        var groups: [CanonicalChord: [HotkeyConflict.Participant]] = [:]
        // Iterating sorted by spoon name keeps participant ordering
        // deterministic (and the resulting conflict list stable).
        for spoonName in spoons.keys.sorted() {
            let actions = spoons[spoonName] ?? [:]
            for actionName in actions.keys.sorted() {
                let binding = actions[actionName]!
                let chord = CanonicalChord(binding: binding)
                groups[chord, default: []].append(
                    HotkeyConflict.Participant(
                        spoonName: spoonName, actionName: actionName))
            }
        }
        return groups
            .filter { $0.value.count >= 2 }
            .map { (chord, participants) in
                HotkeyConflict(
                    binding: chord.canonicalBinding,
                    participants: participants)
            }
            .sorted { $0.binding.key < $1.binding.key ||
                      ($0.binding.key == $1.binding.key
                       && $0.binding.mods.joined() <
                          $1.binding.mods.joined()) }
    }

    /// Returns true iff a single participant is in any conflict group.
    public static func isInConflict(
        participant: HotkeyConflict.Participant,
        conflicts: [HotkeyConflict]
    ) -> Bool {
        return conflicts.contains { conflict in
            conflict.participants.contains(participant)
        }
    }
}

/// Canonical chord key. Modifiers are stored as a sorted-set view (the
/// `mods` array is just a sorted tuple of unique strings), key is
/// lowercased. Suitable as a dictionary key.
private struct CanonicalChord: Hashable {
    let mods: [String]
    let key: String

    init(binding: HotkeyBinding) {
        // Deduplicate modifiers (defensive — input shouldn't contain
        // duplicates, but some hand-authored manifests have done this)
        // and sort to the menu-bar canonical order so the dict key
        // matches across mod-order permutations.
        let uniqueMods = Array(Set(binding.mods))
        self.mods = Hotkey.sortedMods(uniqueMods)
        self.key  = binding.key.lowercased()
    }

    var canonicalBinding: HotkeyBinding {
        return HotkeyBinding(mods: mods, key: key)
    }
}
