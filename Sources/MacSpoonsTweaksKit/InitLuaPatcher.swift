import Foundation

/// Inserts `require("mac_spoons_tweaks")` into the user's
/// `~/.hammerspoon/init.lua` so the snippet we generate actually runs
/// when Hammerspoon starts.
///
/// Two-phase API: `plan()` produces a `PatchPlan` describing what would
/// happen (resolved path after symlink-follow, git-tracking warning,
/// backup filename). The UI shows this to the user; on consent the
/// caller invokes `apply(_:)`.
///
/// Symlink-aware: a developer who symlinks `~/.hammerspoon/init.lua`
/// into a git repo (the dev workflow this project is built on) should
/// have the backup placed next to the real file, not next to the
/// dangling symlink — and should see an "in git tree" warning so they
/// realize they're about to edit a tracked file.
public final class InitLuaPatcher: @unchecked Sendable {

    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public init(status: HammerspoonStatus) {
        self.path = status.initLuaPath
    }

    /// Substring forms we treat as "the require line is already there".
    /// Covers Lua's three call-syntax flavors. Commented-out lines also
    /// match — if the user explicitly opted out we leave the file alone.
    public static let requireForms: [String] = [
        "require(\"mac_spoons_tweaks\")",
        "require \"mac_spoons_tweaks\"",
        "require 'mac_spoons_tweaks'",
    ]

    /// Compute the patch plan without touching the file system. Safe to
    /// call repeatedly; idempotent.
    public func plan(now: Date = Date()) throws -> PatchPlan {
        let original  = path
        let resolved  = resolveSymlink(original)
        let isSymlink = (original.resolvingSymlinksInPath().path != original.path)
                     || isImmediateSymlink(original)

        let existing  = (try? String(contentsOf: resolved, encoding: .utf8)) ?? ""
        let already   = Self.requireForms.contains { existing.contains($0) }

        let backupPath = already
            ? nil
            : backupURL(for: resolved, at: now)

        return PatchPlan(
            originalPath:   original,
            resolvedPath:   resolved,
            isSymlink:      isSymlink,
            isInGitTree:    isInGitTree(near: resolved),
            alreadyApplied: already,
            backupPath:     backupPath)
    }

    /// Apply the plan. Idempotent: a plan with `alreadyApplied == true`
    /// returns `.noOp` without touching any files.
    @discardableResult
    public func apply(_ plan: PatchPlan) throws -> PatchResult {
        if plan.alreadyApplied { return .noOp }

        let target = plan.resolvedPath
        let existing  = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        guard let backupPath = plan.backupPath else {
            // alreadyApplied was false but backupPath was nil — shouldn't
            // be reachable, but bail rather than silently dropping the
            // backup invariant.
            throw PatchError.backupPathMissingFromPlan
        }

        // Ensure containing directory exists (for the rare case where
        // the user has no ~/.hammerspoon yet — fresh Hammerspoon install).
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        if !existing.isEmpty {
            // Take a backup before any mutation. If the user already had
            // an init.lua, the backup name is unique-per-second; collisions
            // (two runs in the same second) get a numeric suffix.
            let actualBackup = uniqueBackupPath(based: backupPath)
            try existing.write(to: actualBackup, atomically: true, encoding: .utf8)
        }

        // Append the require line, ensuring exactly one trailing newline
        // separates it from any prior content.
        var newContent = existing
        if !newContent.isEmpty && !newContent.hasSuffix("\n") {
            newContent += "\n"
        }
        newContent += "require(\"mac_spoons_tweaks\")\n"
        try newContent.write(to: target, atomically: true, encoding: .utf8)

        return .applied(backupPath: backupPath)
    }

    // MARK: - Internals

    /// Build a deterministic backup URL for a target file at a given
    /// time. Suffix is `mac-spoons-tweaks-backup-YYYYmmdd-HHMMSS` —
    /// sortable, no characters the shell or Finder dislike.
    private func backupURL(for target: URL, at date: Date) -> URL {
        let stamp = Self.timestampFormatter.string(from: date)
        return target.deletingLastPathComponent()
            .appendingPathComponent(
                target.lastPathComponent
                + ".mac-spoons-tweaks-backup-" + stamp)
    }

    /// If the planned backup path already exists, find the next free
    /// `.N` suffix. Two runs in the same second (e.g. an automated
    /// test loop) shouldn't clobber each other's backups.
    private func uniqueBackupPath(based proposed: URL) -> URL {
        var url = proposed
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = proposed
                .deletingLastPathComponent()
                .appendingPathComponent(proposed.lastPathComponent + ".\(n)")
            n += 1
        }
        return url
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func resolveSymlink(_ url: URL) -> URL {
        // URL.resolvingSymlinksInPath() also strips redundant components
        // like ".." — that's fine here, the result is still a path that
        // points to the same on-disk file.
        return url.resolvingSymlinksInPath()
    }

    private func isImmediateSymlink(_ url: URL) -> Bool {
        // `URLResourceKey.isSymbolicLinkKey` reports whether the path
        // ITSELF is a symlink, not its target. Foundation's resolved
        // path matches when there's no symlink in the chain — but if
        // the symlink target's path happens to equal the symlink path
        // (loopback / same name on different filesystems), the equality
        // check above could miss it. This is a belt-and-suspenders.
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink ?? false
    }

    /// Walk up from the file looking for a `.git` (either a directory
    /// for a normal repo or a file for a worktree / submodule pointer).
    /// Bails after a reasonable depth so we don't traverse all the way
    /// to root on weird filesystems.
    private func isInGitTree(near file: URL) -> Bool {
        var current = file.deletingLastPathComponent()
        for _ in 0..<32 {
            let candidate = current.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return true
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return false }
            current = parent
        }
        return false
    }
}

// MARK: - Public types

public struct PatchPlan: Equatable, Sendable {
    /// The path the caller asked us to patch (usually
    /// `~/.hammerspoon/init.lua`).
    public let originalPath: URL

    /// What the symlink chain resolves to. The actual file that gets
    /// edited — and where the backup is placed next to it.
    public let resolvedPath: URL

    /// True iff `originalPath` involved a symlink. Surfaced to the UI
    /// so the user is told which file will actually be touched.
    public let isSymlink: Bool

    /// True iff the resolved file lives inside a git repo. Advisory:
    /// the patcher will happily edit a tracked file; the UI is expected
    /// to ask the user to confirm so they don't accidentally stage an
    /// auto-generated edit.
    public let isInGitTree: Bool

    /// True iff a recognised `require` form is already present in the
    /// file. When true, `apply(_:)` is a no-op.
    public let alreadyApplied: Bool

    /// Where the backup of the pre-edit file will go. `nil` iff the
    /// plan is already applied (no edit, no backup).
    public let backupPath: URL?
}

public enum PatchResult: Equatable, Sendable {
    case noOp
    case applied(backupPath: URL)
}

public enum PatchError: Error, CustomStringConvertible {
    case backupPathMissingFromPlan

    public var description: String {
        switch self {
        case .backupPathMissingFromPlan:
            return "PatchPlan is inconsistent: alreadyApplied=false but " +
                   "backupPath=nil. Rebuild the plan and try again."
        }
    }
}
