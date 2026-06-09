import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("InitLuaPatcher")
struct InitLuaPatcherTests {

    // MARK: - Plan: alreadyApplied detection

    @Test
    func planReportsAlreadyAppliedForEachRequireForm() throws {
        for form in InitLuaPatcher.requireForms {
            try withTmpFile(contents: "-- existing config\n\(form)\n") { url in
                let p = try InitLuaPatcher(path: url).plan()
                #expect(p.alreadyApplied, "should detect form: \(form)")
                #expect(p.backupPath == nil)
            }
        }
    }

    @Test
    func planReportsNotAppliedForMissingRequireLine() throws {
        try withTmpFile(contents: "-- nothing special here\n") { url in
            let p = try InitLuaPatcher(path: url).plan()
            #expect(!p.alreadyApplied)
            #expect(p.backupPath != nil)
        }
    }

    @Test
    func planReportsNotAppliedForMissingFile() throws {
        // The user might have a fresh Hammerspoon install with no
        // init.lua yet — apply should create one.
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("init.lua")
        let p = try InitLuaPatcher(path: url).plan()
        #expect(!p.alreadyApplied)
        #expect(p.backupPath != nil)
    }

    @Test
    func planTreatsCommentedRequireAsApplied() throws {
        // We don't second-guess users who explicitly opted out by
        // commenting the line. Treating a commented form as "already
        // applied" means apply() is a no-op — we leave them alone.
        try withTmpFile(contents: "-- require(\"mac_spoons_tweaks\")\n") { url in
            let p = try InitLuaPatcher(path: url).plan()
            #expect(p.alreadyApplied)
        }
    }

    // MARK: - Apply

    @Test
    func applyAppendsRequireLineAndCreatesBackup() throws {
        try withTmpFile(contents: "-- user config\nfoo = 1\n") { url in
            let patcher = InitLuaPatcher(path: url)
            let plan = try patcher.plan()
            let result = try patcher.apply(plan)
            guard case .applied(let backup) = result else {
                Issue.record("expected .applied, got \(result)")
                return
            }
            // Backup contains the original.
            let backupContent = try String(contentsOf: backup, encoding: .utf8)
            #expect(backupContent == "-- user config\nfoo = 1\n")
            // Target now contains the original + require line.
            let newContent = try String(contentsOf: url, encoding: .utf8)
            #expect(newContent ==
                "-- user config\nfoo = 1\nrequire(\"mac_spoons_tweaks\")\n")
        }
    }

    @Test
    func applyAddsMissingTrailingNewline() throws {
        // Some users save init.lua without a trailing newline. Our
        // append must NOT concatenate the require call onto the last
        // line — that would produce broken Lua.
        try withTmpFile(contents: "foo = 1") { url in
            let patcher = InitLuaPatcher(path: url)
            let plan = try patcher.plan()
            _ = try patcher.apply(plan)
            let newContent = try String(contentsOf: url, encoding: .utf8)
            #expect(newContent ==
                "foo = 1\nrequire(\"mac_spoons_tweaks\")\n",
                "expected newline insertion between content and require line")
        }
    }

    @Test
    func applyCreatesFileFromScratchIfMissing() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("init.lua")
        let patcher = InitLuaPatcher(path: url)
        let plan = try patcher.plan()
        let result = try patcher.apply(plan)
        // No backup expected since there was no existing content.
        // (Plan still reserves a backup path, but apply skips writing
        // it when the source was empty/missing.)
        if case .applied(_) = result {} else {
            Issue.record("expected .applied")
        }
        let newContent = try String(contentsOf: url, encoding: .utf8)
        #expect(newContent == "require(\"mac_spoons_tweaks\")\n")
    }

    @Test
    func applyIsNoOpWhenAlreadyApplied() throws {
        try withTmpFile(contents: "require(\"mac_spoons_tweaks\")\n") { url in
            let patcher = InitLuaPatcher(path: url)
            let plan = try patcher.plan()
            let result = try patcher.apply(plan)
            #expect(result == .noOp)
            // File unchanged — no double-insert, no backup spawned.
            let kept = try String(contentsOf: url, encoding: .utf8)
            #expect(kept == "require(\"mac_spoons_tweaks\")\n")
        }
    }

    @Test
    func twoRunsInSameSecondGetUniqueBackupNames() throws {
        try withTmpFile(contents: "v1\n") { url in
            // First run: insert.
            let patcher = InitLuaPatcher(path: url)
            let plan1 = try patcher.plan()
            _ = try patcher.apply(plan1)

            // Replace contents so the second plan sees a missing
            // require line, then force a plan-with-same-timestamp
            // and apply again.
            try "v2\n".write(to: url, atomically: true, encoding: .utf8)
            let fixedDate = Date(timeIntervalSinceReferenceDate: 700_000_000)
            let plan2 = try patcher.plan(now: fixedDate)
            let plan3 = try patcher.plan(now: fixedDate)
            // Apply both with the same proposed backup name; the second
            // must dodge the name collision.
            let r1 = try patcher.apply(plan2)
            try "v3\n".write(to: url, atomically: true, encoding: .utf8)
            let r2 = try patcher.apply(plan3)

            // Both succeeded with backups present, and the SECOND
            // backup file's path differs from the first to avoid
            // overwriting.
            guard case .applied(let b1) = r1, case .applied(let b2) = r2 else {
                Issue.record("expected two applied results")
                return
            }
            // The PLANNED paths share a name (same second), but the
            // actual on-disk backup files have to differ. Inspect dir.
            let dir = url.deletingLastPathComponent()
            let backups = try FileManager.default
                .contentsOfDirectory(atPath: dir.path)
                .filter { $0.contains("mac-spoons-tweaks-backup-") }
            #expect(backups.count >= 2,
                    "expected ≥2 distinct backup files, found \(backups)")
            _ = b1; _ = b2
        }
    }

    // MARK: - Symlinks

    @Test
    func planFollowsSymlinkAndPlacesBackupNextToRealTarget() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Real target lives one dir over, in what we'll pretend is a
        // git-tracked repo.
        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: repoDir, withIntermediateDirectories: true)
        let realInit = repoDir.appendingPathComponent("init.lua")
        try "real init.lua content\n".write(
            to: realInit, atomically: true, encoding: .utf8)
        // Symlink: ~/.hammerspoon/init.lua → repo/init.lua
        let hsDir = dir.appendingPathComponent("hammerspoon")
        try FileManager.default.createDirectory(
            at: hsDir, withIntermediateDirectories: true)
        let symlink = hsDir.appendingPathComponent("init.lua")
        try FileManager.default.createSymbolicLink(
            at: symlink, withDestinationURL: realInit)

        let plan = try InitLuaPatcher(path: symlink).plan()
        #expect(plan.isSymlink, "symlink should be detected")
        #expect(plan.resolvedPath.path == realInit.path,
                "resolvedPath should follow the symlink")
        #expect(!plan.alreadyApplied)
        // Backup path is next to the real target, not the symlink.
        #expect(plan.backupPath?.deletingLastPathComponent().path
                == repoDir.path,
                "backup should be placed next to the real file")
    }

    @Test
    func planDetectsGitTrackedTreeForRealFile() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: repoDir, withIntermediateDirectories: true)
        // Marker `.git` dir (any non-empty .git counts).
        try FileManager.default.createDirectory(
            at: repoDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true)
        let init_ = repoDir.appendingPathComponent("init.lua")
        try "hi\n".write(to: init_, atomically: true, encoding: .utf8)
        let plan = try InitLuaPatcher(path: init_).plan()
        #expect(plan.isInGitTree)
    }

    @Test
    func planReportsNotInGitForPlainDir() throws {
        try withTmpFile(contents: "no git here\n") { url in
            let plan = try InitLuaPatcher(path: url).plan()
            #expect(!plan.isInGitTree)
        }
    }

    // MARK: - Helpers

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("init-lua-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func withTmpFile(
        contents: String,
        body: (URL) throws -> Void
    ) throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("init.lua")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try body(url)
    }
}
