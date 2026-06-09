import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("CatalogDriftDetector")
struct CatalogDriftDetectorTests {

    @Test
    func nilSnapshotMeansNoDriftRatherThanFullChange() {
        // installedSchemaKeys == nil → install predates the feature.
        // We must NOT report every field as "added" — that would
        // pop the notice on existing installs the first time the
        // upgraded app runs.
        let entry = makeEntry(keys: ["delay", "excludedApps"])
        let drift = CatalogDriftDetector.detect(
            installedKeys: nil, currentEntry: entry)
        #expect(drift.isEmpty)
    }

    @Test
    func emptyDriftWhenSnapshotMatches() {
        let entry = makeEntry(keys: ["delay", "excludedApps"])
        let drift = CatalogDriftDetector.detect(
            installedKeys: ["delay", "excludedApps"],
            currentEntry: entry)
        #expect(drift.isEmpty)
    }

    @Test
    func detectsAddedFields() {
        // Catalog grew "newField" since install.
        let entry = makeEntry(keys: ["delay", "newField"])
        let drift = CatalogDriftDetector.detect(
            installedKeys: ["delay"], currentEntry: entry)
        #expect(drift.addedKeys == ["newField"])
        #expect(drift.removedKeys.isEmpty)
        #expect(!drift.isEmpty)
    }

    @Test
    func detectsRemovedFields() {
        // Catalog dropped "oldField" since install.
        let entry = makeEntry(keys: ["delay"])
        let drift = CatalogDriftDetector.detect(
            installedKeys: ["delay", "oldField"],
            currentEntry: entry)
        #expect(drift.removedKeys == ["oldField"])
        #expect(drift.addedKeys.isEmpty)
    }

    @Test
    func detectsBothAddedAndRemoved() {
        let entry = makeEntry(keys: ["a", "b", "newer"])
        let drift = CatalogDriftDetector.detect(
            installedKeys: ["a", "older"],
            currentEntry: entry)
        #expect(drift.addedKeys == ["b", "newer"])
        #expect(drift.removedKeys == ["older"])
    }

    @Test
    func snapshotSortsKeys() {
        let entry = makeEntry(keys: ["zebra", "alpha", "mango"])
        let keys = CatalogDriftDetector.snapshotKeys(from: entry)
        #expect(keys == ["alpha", "mango", "zebra"])
    }

    @Test
    func snapshotIgnoresOrderingInOutputs() {
        // Regardless of catalog field declaration order, the snapshot
        // sorts deterministically. This makes installedSchemaKeys
        // diff-stable in state.json.
        let entry1 = makeEntry(keys: ["a", "b"])
        let entry2 = makeEntry(keys: ["b", "a"])
        #expect(CatalogDriftDetector.snapshotKeys(from: entry1)
                == CatalogDriftDetector.snapshotKeys(from: entry2))
    }

    // MARK: helpers

    private func makeEntry(keys: [String]) -> SpoonCatalogEntry {
        let config: [ConfigField] = keys.map { key in
            .bool(BoolField(
                key: key, label: nil, description: nil,
                advanced: nil, requires: nil, default: false))
        }
        return SpoonCatalogEntry(
            id: "test:Spoon", name: "Spoon", sourceID: "catokolas",
            metadata: SpoonMetadata(version: "0.1", description: nil,
                                    author: nil, homepage: nil,
                                    license: nil),
            lifecycle: Lifecycle(hasStart: true, hasStop: true,
                                 hasToggle: false,
                                 hasConfigure: true,
                                 eventDriven: false),
            config: config, hotkeys: [],
            provenance: .manifest)
    }
}
