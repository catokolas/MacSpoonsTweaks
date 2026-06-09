import Foundation

/// Lua-script builders for talking to the live `SpoonInstall.spoon`
/// (as opposed to plain Spoon lifecycle calls in `HammerspoonScript`).
///
/// Mirrors the SpoonInstall API documented at
/// <https://www.hammerspoon.org/Spoons/SpoonInstall.html>. Splitting
/// these builders out so the installer's behavior can be unit-tested by
/// asserting on the generated script strings.
public enum SpoonInstallScript {

    /// Idempotent: loads SpoonInstall iff it isn't already loaded.
    /// We always emit this guard so the snippet is safe to run in a
    /// session where the user (or a previous app run) already loaded
    /// it — `hs.loadSpoon` is itself idempotent but emits a log line
    /// per call, and we'd rather keep the console quiet.
    public static let ensureLoaded: String =
        "if not spoon.SpoonInstall then hs.loadSpoon(\"SpoonInstall\") end"

    /// Assignment to `spoon.SpoonInstall.repos[<id>]`. The official
    /// `default` repo is built into SpoonInstall and must NOT be
    /// re-registered (overwriting it could change branch/url under the
    /// user's feet on a future SpoonInstall upgrade). Callers should
    /// skip this for `id == "default"`.
    public static func registerRepo(
        id: String, url: String, branch: String, desc: String?
    ) -> String {
        var fields: [String: ConfigValue] = [
            "url":    .string(url),
            "branch": .string(branch),
        ]
        if let desc = desc { fields["desc"] = .string(desc) }
        let table = LuaLiteral.encodeTable(fields)
        return "spoon.SpoonInstall.repos[\(LuaLiteral.encodeString(id))] = \(table)"
    }

    /// Fetch the repo's `docs/docs.json` so subsequent installs can
    /// resolve the Spoon name to a zip URL. The sync variant blocks
    /// Hammerspoon briefly — acceptable for an app-initiated install
    /// where the user is waiting for feedback.
    public static func updateRepo(id: String) -> String {
        return "spoon.SpoonInstall:updateRepo(\(LuaLiteral.encodeString(id)))"
    }

    /// Synchronous install — blocks Hammerspoon while it downloads,
    /// unzips, and places the Spoon. Returns the literal string
    /// `"ok"` on success or `"fail"` on failure so the Swift side can
    /// parse a definite outcome without depending on stdout shape.
    public static func installFromRepo(name: String, repoID: String) -> String {
        let n = LuaLiteral.encodeString(name)
        let r = LuaLiteral.encodeString(repoID)
        return """
            spoon.SpoonInstall.use_syncinstall = true
            local ok = spoon.SpoonInstall:installSpoonFromRepo(\(n), \(r))
            return ok and "ok" or "fail"
            """
    }

    /// Full install script — composes ensureLoaded → registerRepo (if
    /// non-default) → updateRepo → installFromRepo. Single round-trip
    /// to `hs -c`, so the user only waits for one process spawn.
    public static func install(
        name: String, repo: RepoRef
    ) -> String {
        var lines: [String] = [ensureLoaded]
        switch repo {
        case .default:
            break
        case .custom(let id, let url, let branch, let desc):
            lines.append(registerRepo(
                id: id, url: url, branch: branch, desc: desc))
        }
        lines.append(updateRepo(id: repo.id))
        lines.append(installFromRepo(name: name, repoID: repo.id))
        return lines.joined(separator: "\n")
    }

    /// Stop the Spoon (if it has a `:stop()` method), then clear its
    /// references from the namespace so a future load doesn't see a
    /// stale instance. The Swift side handles the on-disk removal.
    public static func unload(name: String) -> String {
        // pcall around :stop() so a Spoon that errors during shutdown
        // doesn't block the unload — we'd rather see the broken Spoon
        // disappear than have the user stuck with a half-removed one.
        return """
            if spoon.\(name) and spoon.\(name).stop then
              pcall(function() spoon.\(name):stop() end)
            end
            spoon.\(name) = nil
            package.loaded[\(LuaLiteral.encodeString("spoon." + name))] = nil
            package.loaded[\(LuaLiteral.encodeString(name))] = nil
            """
    }
}

/// Which SpoonInstall repo a Spoon is being installed from. `.default`
/// is the built-in `Hammerspoon/Spoons`; `.custom` is anything we
/// register at runtime (e.g. our own `catokolas` repo).
public enum RepoRef: Sendable, Equatable {
    case `default`
    case custom(id: String, url: String, branch: String, desc: String?)

    public var id: String {
        switch self {
        case .default:           return "default"
        case .custom(let id, _, _, _): return id
        }
    }
}
