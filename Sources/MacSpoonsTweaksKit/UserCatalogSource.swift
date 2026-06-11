import Foundation

/// `CatalogSource` backed by a user-added GitHub repo that publishes a
/// `SpoonsCatalog`-shape `spoons.json` at the root of a branch. Mirrors
/// the `CatokolasSource` ETag-cached fetch and same `decode(...)` path
/// — third-party catalogs are expected to use the same
/// `tools/build-manifest.lua` workflow `HS_SpoonsContrib` ships.
///
/// `id` is namespaced as `"user:<owner>/<repo>"` so it never collides
/// with the built-in `catokolas` / `hammerspoon-official` sources, and
/// so the snippet's repo registrations stay distinguishable.
public final class UserCatalogSource: CatalogSource, @unchecked Sendable {
    public let config:    CustomCatalogConfig
    public let id:        String

    private let catalogURL: URL
    private let cacheDir:   URL
    private let session:    URLSession

    public init(
        config:   CustomCatalogConfig,
        cacheDir: URL? = nil,
        session:  URLSession = .shared
    ) {
        self.config     = config
        self.id         = "user:\(config.id)"
        self.catalogURL = URL(string:
            "https://raw.githubusercontent.com/"
            + "\(config.owner)/\(config.repo)/\(config.branch)/spoons.json"
        )!
        self.cacheDir   = cacheDir ?? UserCatalogSource.defaultCacheDir()
        self.session    = session
    }

    public func refresh() async throws -> [SpoonCatalogEntry] {
        try FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true)

        let payloadPath = cacheDir
            .appendingPathComponent("\(safeFilename).json")
        let etagPath = cacheDir
            .appendingPathComponent("\(safeFilename).etag")

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

    /// Pure decode path. Public for tests. Doesn't pick up `overrides`
    /// — third-party catalogs don't get to rewrite other sources'
    /// entries (that's a catokolas-only convention).
    public func decode(_ data: Data) throws -> [SpoonCatalogEntry] {
        let catalog = try JSONDecoder().decode(SpoonsCatalog.self, from: data)
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
                    license:     manifest.license),
                lifecycle:       manifest.lifecycle,
                config:          manifest.config,
                hotkeys:         manifest.hotkeys,
                optionalModules: manifest.optionalModules,
                knownIssues:     manifest.knownIssues,
                provenance:      .manifest)
        }
    }

    /// File-system-safe form of `id` for the cache filenames.
    private var safeFilename: String {
        return id.replacingOccurrences(of: "/", with: "_")
                 .replacingOccurrences(of: ":", with: "_")
    }

    private static func defaultCacheDir() -> URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("MacSpoonsTweaks")
            .appendingPathComponent("user-catalogs")
    }
}

public extension UserCatalogSource {
    /// SpoonInstall repo descriptor — registers this catalog's git
    /// remote so `:installSpoonFromRepo` can fetch Spoons from it.
    var repoRef: RepoRef {
        return .custom(
            id:     id,
            url:    "https://github.com/\(config.owner)/\(config.repo)",
            branch: config.branch,
            desc:   config.description
                ?? "User-added catalog \(config.id)")
    }

    /// Same update-check strategy as catokolas — clone the repo
    /// shallowly and resolve the latest commit on the configured branch.
    func updateCheckStrategy(
        for entry: SpoonCatalogEntry
    ) -> UpdateCheckStrategy {
        return .gitCommitForSubdir(
            repo:   URL(string:
                "https://github.com/\(config.owner)/\(config.repo)")!,
            subdir: "\(entry.name).spoon",
            ref:    config.branch)
    }
}
