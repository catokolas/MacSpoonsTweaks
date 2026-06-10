import Foundation

/// `CatalogSource` backed by the rich `spoons.json` published in
/// `catokolas/HS_SpoonsContrib`. Fetches over HTTPS with ETag caching;
/// falls back to the on-disk cache if the network is unavailable.
///
/// Also carries the `overrides` block from the published `spoons.json`,
/// which other sources (e.g. `HammerspoonOfficialSource`) merge into
/// their entries via `OverrideApplier`.
public final class CatokolasSource: CatalogSource, @unchecked Sendable {
    public let id = "catokolas"

    private let catalogURL: URL
    private let cacheDir:   URL
    private let session:    URLSession

    /// Locked-access store of the most recent overrides decoded from
    /// `spoons.json`. Read via `overridesForUpstream`.
    private let lock = NSLock()
    private var _overrides: [String: SpoonManifest] = [:]

    public init(
        catalogURL: URL = URL(
            string: "https://raw.githubusercontent.com/catokolas/HS_SpoonsContrib/main/spoons.json"
        )!,
        cacheDir: URL? = nil,
        session:  URLSession = .shared
    ) {
        self.catalogURL = catalogURL
        self.cacheDir   = cacheDir ?? CatokolasSource.defaultCacheDir()
        self.session    = session
    }

    public var overridesForUpstream: [String: SpoonManifest] {
        lock.lock(); defer { lock.unlock() }
        return _overrides
    }

    public func refresh() async throws -> [SpoonCatalogEntry] {
        try FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true
        )
        let payloadPath = cacheDir.appendingPathComponent("catokolas.json")
        let etagPath    = cacheDir.appendingPathComponent("catokolas.etag")

        var request = URLRequest(url: catalogURL)
        if let etag = try? String(contentsOf: etagPath, encoding: .utf8),
           FileManager.default.fileExists(atPath: payloadPath.path) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse

            if http?.statusCode == 304,
               let cached = try? Data(contentsOf: payloadPath) {
                return try decode(cached)
            }

            // Other non-2xx → fall through to the on-disk cache if present,
            // else surface the error.
            if let status = http?.statusCode, !(200..<300).contains(status) {
                if let cached = try? Data(contentsOf: payloadPath) {
                    return try decode(cached)
                }
                throw CatalogError.httpStatus(status)
            }

            try data.write(to: payloadPath, options: .atomic)
            if let etag = http?.value(forHTTPHeaderField: "ETag") {
                try etag.write(to: etagPath, atomically: true, encoding: .utf8)
            }
            return try decode(data)
        } catch {
            // Network errors degrade to whatever's in the cache.
            if let cached = try? Data(contentsOf: payloadPath) {
                return try decode(cached)
            }
            throw error
        }
    }

    func decode(_ data: Data) throws -> [SpoonCatalogEntry] {
        let catalog = try JSONDecoder().decode(SpoonsCatalog.self, from: data)
        // Capture the overrides so other CatalogSource implementations
        // can consume them via `overridesForUpstream`.
        lock.lock()
        _overrides = catalog.overrides
        lock.unlock()
        return catalog.spoons.map { manifest in
            SpoonCatalogEntry(
                id:        "\(id):\(manifest.name)",
                name:      manifest.name,
                sourceID:  id,
                metadata:  SpoonMetadata(
                    version:     manifest.version,
                    description: manifest.description,
                    author:      manifest.author,
                    homepage:    manifest.homepage,
                    license:     manifest.license
                ),
                lifecycle:       manifest.lifecycle,
                config:          manifest.config,
                hotkeys:         manifest.hotkeys,
                optionalModules: manifest.optionalModules,
                provenance:      .manifest
            )
        }
    }

    private static func defaultCacheDir() -> URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("MacSpoonsTweaks")
            .appendingPathComponent("catalog")
    }
}

public enum CatalogError: Error {
    case httpStatus(Int)
}
