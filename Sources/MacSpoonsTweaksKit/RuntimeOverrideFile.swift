import Foundation

/// Tiny Lua-readable file Hammerspoon writes when the user toggles a
/// Spoon on/off via its activate-hotkey. Survives `hs.reload()` so
/// chord-triggered deactivations persist; MacSpoonsTweaks reads + clears
/// it at next launch and pushes the new state into `state.json`.
///
/// On-disk shape — a Lua return statement, one entry per currently
/// deactivated Spoon:
///
/// ```lua
/// -- mac_spoons_tweaks_overrides.lua — MANAGED FILE — DO NOT EDIT.
/// -- Written by the activate-hotkey closure; read by the snippet at
/// -- startup and by MacSpoonsTweaks at launch.
/// return {
///   FocusFollowsMouse = true,
///   MouseScrollTweaks = true,
/// }
/// ```
///
/// Absent file (or empty table) = "no chord-driven overrides; honor the
/// snippet's `start = true` defaults". The file is deleted when the set
/// is empty so a stale `return {}` doesn't keep claiming overrides.
public final class RuntimeOverrideFile: @unchecked Sendable {

    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    /// Default location alongside `mac_spoons_tweaks.lua` in
    /// `~/.hammerspoon/`. Both files have to live in the same dir so
    /// the snippet can `dofile()` this one with a fixed path.
    public static func defaultPath() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".hammerspoon", isDirectory: true)
            .appendingPathComponent(
                "mac_spoons_tweaks_overrides.lua", isDirectory: false)
    }

    // MARK: - Read

    /// Parse the names of deactivated Spoons. Returns an empty set if
    /// the file is missing, unreadable, or malformed — we never throw
    /// because a busted override file shouldn't block the app from
    /// loading the catalog.
    public func read() -> Set<String> {
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return parse(text)
    }

    // MARK: - Write

    /// Replace the file with one entry per name in `deactivated`. The
    /// empty set yields a `return {}` body — we keep the file rather
    /// than deleting so the Swift-side FS watcher stays attached across
    /// transitions. Snippet reads via `pcall(dofile, …)` and treats
    /// empty as "no overrides", same as a missing file.
    public func write(_ deactivated: Set<String>) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let body = render(deactivated)
        try body.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Create the file on disk if it doesn't already exist, with an
    /// empty `return {}` body. Lets the app's FS watcher attach at
    /// launch even before the first chord toggle has happened.
    public func ensureExists() throws {
        if !FileManager.default.fileExists(atPath: path.path) {
            try write([])
        }
    }

    /// Add or remove a single Spoon name from the file in one shot.
    /// Convenience used by the orchestrator's `setPaused` path.
    public func setDeactivated(_ name: String, _ deactivated: Bool) throws {
        var current = read()
        if deactivated {
            current.insert(name)
        } else {
            current.remove(name)
        }
        try write(current)
    }

    // MARK: - Watch

    /// Poll-based watcher. `handler` runs on `DispatchQueue.main` each
    /// time the file's content changes — detected by size + mtime so a
    /// re-write that lands the same bytes is silently ignored. Polling
    /// (vs. `DispatchSource.makeFileSystemObjectSource`) is the reliable
    /// path for in-place writes from Lua's `io.open(path, "w")`: kqueue
    /// events on that pattern are flaky on macOS Tahoe, and even when
    /// they fire they can race the kernel's write buffer. 300 ms is
    /// fast enough that chord → slider feels instant, slow enough that
    /// the work per tick (one `stat`) is invisible on a power budget.
    public func startPolling(
        every interval: TimeInterval = 0.3,
        handler: @escaping () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        var lastHash = self.contentHash()
        timer.setEventHandler {
            let current = self.contentHash()
            if current != lastHash {
                lastHash = current
                handler()
            }
        }
        timer.resume()
        return timer
    }

    /// Cheap "did this file change?" stamp. Combines size + last-modified
    /// time. Avoids reading the whole file every tick.
    private func contentHash() -> String {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path.path)
        else { return "missing" }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? 0
        return "\(size):\(mtime)"
    }

    // MARK: - Internals

    /// Render the Lua return-statement body.
    private func render(_ deactivated: Set<String>) -> String {
        var out = "-- mac_spoons_tweaks_overrides.lua — MANAGED FILE — DO NOT EDIT.\n"
        out += "-- Written by the activate-hotkey closure in mac_spoons_tweaks.lua\n"
        out += "-- and reconciled at MacSpoonsTweaks launch.\n"
        out += "return {\n"
        for name in deactivated.sorted() {
            out += "  \(name) = true,\n"
        }
        out += "}\n"
        return out
    }

    /// Lightweight Lua-table-literal parser. Looks for
    /// `<identifier> = true` rows inside the `return { … }` block.
    /// Robust to comments, whitespace, trailing commas. Not a general
    /// Lua parser — the file is ours and the format is fixed.
    private func parse(_ text: String) -> Set<String> {
        var out: Set<String> = []
        for rawLine in text.split(separator: "\n",
                                  omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("--") { continue }
            // Match `NAME = true,?` (we don't honour `false` —
            // absence is the only "active" signal).
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
            // Strip trailing comma if present so "true," matches "true".
            let value = rest.hasSuffix(",")
                ? String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
                : rest
            guard value == "true",
                  !key.isEmpty,
                  key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else { continue }
            out.insert(key)
        }
        return out
    }
}
