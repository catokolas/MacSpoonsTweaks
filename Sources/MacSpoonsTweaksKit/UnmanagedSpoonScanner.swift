import Foundation

/// A `.spoon` directory the app didn't install — typically a symlink
/// into a sibling dev repo, or a manually-installed Spoon predating
/// MacSpoonsTweaks. Surfaced in the sidebar so the user knows what
/// else is in `~/.hammerspoon/Spoons/`.
public struct UnmanagedSpoon: Identifiable, Equatable, Sendable {
    /// Spoon's name without the `.spoon` suffix.
    public let name: String

    /// Absolute path to the `.spoon` directory.
    public let path: URL

    /// True iff `path` itself is a symbolic link.
    public let isSymlink: Bool

    /// If `isSymlink == true`, the resolved real path the symlink
    /// points to. `nil` otherwise.
    public let symlinkTarget: URL?

    public var id: String { name }

    public init(
        name: String,
        path: URL,
        isSymlink: Bool,
        symlinkTarget: URL?
    ) {
        self.name = name
        self.path = path
        self.isSymlink = isSymlink
        self.symlinkTarget = symlinkTarget
    }
}

/// Scanner for `~/.hammerspoon/Spoons/`. Pure — caller passes the
/// directory and the set of managed Spoon names (i.e. names that
/// already have an `installedRef` in `state.json`); the scanner
/// returns everything else.
///
/// `SpoonInstall.spoon` is always excluded — we own it via the
/// bootstrap and the user shouldn't see it in the unmanaged list.
public enum UnmanagedSpoonScanner {

    public static let ownedNames: Set<String> = ["SpoonInstall"]

    public static func scan(
        spoonsDir: URL,
        excluding managed: Set<String> = []
    ) -> [UnmanagedSpoon] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: spoonsDir,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        else {
            return []
        }

        var out: [UnmanagedSpoon] = []
        for entry in entries {
            let fileName = entry.lastPathComponent
            guard fileName.hasSuffix(".spoon") else { continue }
            let name = String(fileName.dropLast(".spoon".count))
            if managed.contains(name)         { continue }
            if ownedNames.contains(name)      { continue }

            let values = try? entry.resourceValues(
                forKeys: [.isSymbolicLinkKey])
            let isSymlink = values?.isSymbolicLink ?? false
            // Resolve only when symlinked; for plain dirs the path IS
            // the location.
            let target: URL? = isSymlink
                ? entry.resolvingSymlinksInPath()
                : nil

            out.append(UnmanagedSpoon(
                name: name,
                path: entry,
                isSymlink: isSymlink,
                symlinkTarget: target))
        }
        return out.sorted { $0.name < $1.name }
    }
}
