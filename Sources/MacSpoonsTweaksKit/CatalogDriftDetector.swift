import Foundation

/// Difference between the config schema captured at install time and
/// the schema in the currently-loaded catalog. Empty when nothing has
/// changed — UI hides the notice in that case.
public struct CatalogDrift: Equatable, Sendable {
    /// Field keys present in the current catalog but NOT in the
    /// install-time snapshot. Sorted alphabetically for stable display.
    public let addedKeys: [String]
    /// Field keys present in the snapshot but missing from the current
    /// catalog. Sorted alphabetically.
    public let removedKeys: [String]

    public var isEmpty: Bool {
        return addedKeys.isEmpty && removedKeys.isEmpty
    }

    public init(addedKeys: [String], removedKeys: [String]) {
        self.addedKeys   = addedKeys
        self.removedKeys = removedKeys
    }
}

/// Detect drift between an install-time schema snapshot and the
/// current catalog entry. We track top-level field keys only; nested
/// fields under `.object` aren't the main churn driver and treating
/// the inner tree as opaque keeps the notice signal high.
public enum CatalogDriftDetector {

    /// `installedKeys == nil` means "we don't know — installed before
    /// the schema-snapshot feature shipped." Returns empty drift in
    /// that case so a missing snapshot isn't surfaced as a change.
    public static func detect(
        installedKeys: [String]?,
        currentEntry: SpoonCatalogEntry
    ) -> CatalogDrift {
        guard let installed = installedKeys else {
            return CatalogDrift(addedKeys: [], removedKeys: [])
        }
        let current = Set(currentEntry.config.map(\.key))
        let snap    = Set(installed)
        return CatalogDrift(
            addedKeys:   current.subtracting(snap).sorted(),
            removedKeys: snap.subtracting(current).sorted())
    }

    /// Snapshot a catalog entry's current top-level schema. Used at
    /// install time and after Apply to keep the comparison baseline
    /// honest.
    public static func snapshotKeys(
        from entry: SpoonCatalogEntry
    ) -> [String] {
        return entry.config.map(\.key).sorted()
    }
}
