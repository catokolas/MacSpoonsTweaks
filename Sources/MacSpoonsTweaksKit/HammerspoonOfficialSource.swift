import Foundation

/// `CatalogSource` backed by the official `Hammerspoon/Spoons` repo.
/// Fetches `docs/docs.json` over HTTPS (the same file SpoonInstall
/// reads when `:updateRepo("default")` runs), ETag-caches it, then runs
/// `DocsJSONInference` to produce typed catalog entries.
///
/// Upstream Spoons inherit `.inferred` config provenance. Once an
/// override manifest from our repo is applied, the entry's provenance
/// flips to `.override(of: ...)` — that wiring lands with Phase 11.
public final class HammerspoonOfficialSource: CatalogSource {
    public let id = "hammerspoon-official"

    private let catalogURL: URL
    private let cacheDir:   URL
    private let session:    URLSession

    public init(
        catalogURL: URL = URL(
            string: "https://raw.githubusercontent.com/Hammerspoon/Spoons/master/docs/docs.json"
        )!,
        cacheDir: URL? = nil,
        session:  URLSession = .shared
    ) {
        self.catalogURL = catalogURL
        self.cacheDir   = cacheDir ?? HammerspoonOfficialSource.defaultCacheDir()
        self.session    = session
    }

    public func refresh() async throws -> [SpoonCatalogEntry] {
        try FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true)

        let payloadPath = cacheDir
            .appendingPathComponent("hammerspoon-official.json")
        let etagPath    = cacheDir
            .appendingPathComponent("hammerspoon-official.etag")

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
            if let cached = try? Data(contentsOf: payloadPath) {
                return try decode(cached)
            }
            throw error
        }
    }

    /// Pure decode → entries path. Internal so tests can drive it with
    /// fixture bytes; the HTTP layer above is what the production app
    /// uses on every refresh.
    func decode(_ data: Data) throws -> [SpoonCatalogEntry] {
        let modules = try JSONDecoder()
            .decode([UpstreamModule].self, from: data)
        return DocsJSONInference.entries(from: modules)
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

// MARK: - UpdateCheckStrategy override

public extension HammerspoonOfficialSource {
    /// Each upstream Spoon's installable artifact lives at
    /// `Hammerspoon/Spoons/raw/master/Spoons/<Name>.spoon.zip` (the
    /// same URL pattern `SpoonInstall:installSpoonFromRepo("default")`
    /// hits). A `HEAD` against this URL returns the ETag we compare
    /// against `state.spoons[name].installedRef.value`.
    func updateCheckStrategy(for entry: SpoonCatalogEntry) -> UpdateCheckStrategy {
        let url = URL(string:
            "https://github.com/Hammerspoon/Spoons/raw/master/Spoons/"
            + entry.name + ".spoon.zip")!
        return .zipETag(url)
    }
}
