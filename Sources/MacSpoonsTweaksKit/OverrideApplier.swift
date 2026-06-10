import Foundation

/// Applies override manifests (curated by us in `HS_SpoonsContrib`'s
/// `overrides/upstream/` directory and aggregated into `spoons.json`)
/// to upstream catalog entries.
///
/// An override gives a popular upstream Spoon a hand-authored config
/// schema (enums with labels, sliders with min/max, structured
/// `object` groups for nested tables) — much nicer than the
/// best-effort `DocsJSONInference` output. The override's
/// `config` and `hotkeys` arrays REPLACE the inferred ones; the
/// `lifecycle` block also replaces the inferred one (overrides
/// frequently correct lifecycle mistakes — e.g. asserting
/// `hasConfigure: false` on a Spoon whose `configure` method is
/// actually a no-op).
///
/// Metadata (name, version, description, author, homepage, license)
/// from the override fills in any fields the upstream module didn't
/// document.
public enum OverrideApplier {

    public static func apply(
        entries: [SpoonCatalogEntry],
        overrides: [String: SpoonManifest]
    ) -> [SpoonCatalogEntry] {
        return entries.map { entry in
            guard let override = overrides[entry.name] else {
                return entry
            }
            return merged(entry: entry, override: override)
        }
    }

    static func merged(
        entry: SpoonCatalogEntry,
        override: SpoonManifest
    ) -> SpoonCatalogEntry {
        let metadata = SpoonMetadata(
            version:     pickNonEmpty(override.version, entry.metadata.version),
            description: override.description    ?? entry.metadata.description,
            author:      override.author         ?? entry.metadata.author,
            homepage:    override.homepage       ?? entry.metadata.homepage,
            license:     override.license        ?? entry.metadata.license)

        return SpoonCatalogEntry(
            id:         entry.id,
            name:       entry.name,
            sourceID:   entry.sourceID,
            metadata:   metadata,
            // Override REPLACES (not merges). The override author owns
            // the schema for this Spoon; merging would mix inferred
            // garbage back into a curated tree.
            lifecycle:        override.lifecycle,
            config:           override.config,
            hotkeys:          override.hotkeys,
            optionalModules:  override.optionalModules,
            provenance:       .override(of: entry.sourceID))
    }

    private static func pickNonEmpty(_ a: String, _ b: String) -> String {
        return a.isEmpty ? b : a
    }
}

// MARK: - CatalogSource overrides hook

/// Sources that fetch their own manifest blob (and can therefore carry
/// curated overrides for OTHER sources' entries) expose them here.
/// Default: no overrides — used by sources that only describe their
/// own Spoons.
///
/// `CatokolasSource` overrides this to return the `overrides` block
/// from the rich `spoons.json` it just fetched. The app's view-model
/// orchestrator unions all sources' overrides and passes the result
/// to `OverrideApplier.apply` on every other source's entries.
public extension CatalogSource {
    /// Overrides captured during the last successful `refresh()`. Empty
    /// before the first refresh and on sources that don't carry any.
    var overridesForUpstream: [String: SpoonManifest] { [:] }
}
