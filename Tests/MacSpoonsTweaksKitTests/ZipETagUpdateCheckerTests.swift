import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("ZipETagUpdateChecker")
struct ZipETagUpdateCheckerTests {

    private let fixedDate = ISO8601DateFormatter().date(
        from: "2026-06-08T12:00:00Z")!

    @Test
    func returnsZipETagRefFromETagHeader() async throws {
        let prober = RecordingHeadProber(responses: [
            HTTPHeadResult(statusCode: 200,
                           etag: "W/\"abc-123\"",
                           lastModified: "Mon, 01 Jan 2026 00:00:00 GMT")
        ])
        let checker = ZipETagUpdateChecker(
            prober: prober, clock: { self.fixedDate })

        let strategy: UpdateCheckStrategy = .zipETag(
            URL(string: "https://example/Caffeine.spoon.zip")!)
        let ref = try await checker.checkLatest(strategy: strategy)
        #expect(ref == .zipETag(value: "W/\"abc-123\"",
                                fetchedAt: fixedDate))
        #expect(prober.requested == [
            URL(string: "https://example/Caffeine.spoon.zip")!
        ])
    }

    @Test
    func fallsBackToLastModifiedWhenNoETag() async throws {
        let prober = RecordingHeadProber(responses: [
            HTTPHeadResult(statusCode: 200,
                           etag: nil,
                           lastModified: "Mon, 01 Jan 2026 00:00:00 GMT")
        ])
        let checker = ZipETagUpdateChecker(
            prober: prober, clock: { self.fixedDate })
        let ref = try await checker.checkLatest(
            strategy: .zipETag(URL(string: "https://example/x.zip")!))
        #expect(ref == .zipETag(
            value: "Mon, 01 Jan 2026 00:00:00 GMT",
            fetchedAt: fixedDate))
    }

    @Test
    func throwsWhenNeitherETagNorLastModifiedPresent() async throws {
        let prober = RecordingHeadProber(responses: [
            HTTPHeadResult(statusCode: 200, etag: nil, lastModified: nil)
        ])
        let checker = ZipETagUpdateChecker(prober: prober)
        await #expect(throws: ZipETagUpdateCheckerError.self) {
            _ = try await checker.checkLatest(
                strategy: .zipETag(URL(string: "https://example/y.zip")!))
        }
    }

    @Test
    func throwsOnHttpErrorStatus() async throws {
        let prober = RecordingHeadProber(responses: [
            HTTPHeadResult(statusCode: 404, etag: nil, lastModified: nil)
        ])
        let checker = ZipETagUpdateChecker(prober: prober)
        await #expect(throws: ZipETagUpdateCheckerError.self) {
            _ = try await checker.checkLatest(
                strategy: .zipETag(URL(string: "https://example/404.zip")!))
        }
    }

    @Test
    func returnsNilForGitStrategy() async throws {
        // ZipETagUpdateChecker should not probe a git strategy — it
        // returns nil so the CompositeUpdateChecker can route to a
        // sibling GitUpdateChecker.
        let prober = RecordingHeadProber()
        let checker = ZipETagUpdateChecker(prober: prober)
        let result = try await checker.checkLatest(
            strategy: .gitCommitForSubdir(
                repo: URL(string: "https://example/repo")!,
                subdir: "X.spoon", ref: "main"))
        #expect(result == nil)
        #expect(prober.requested.isEmpty,
                "should NOT issue HEAD for a git strategy")
    }

    @Test
    func clockInjectionMakesFetchedAtDeterministic() async throws {
        // Same ETag, two checks with different clocks → both return
        // .zipETag with the corresponding fetchedAt. The InstalledRef
        // comparison ignores fetchedAt for equality? Actually it
        // doesn't — `==` on the enum compares all associated values.
        // So a stable clock is what gives us stable refs.
        let prober = RecordingHeadProber(responses: [
            HTTPHeadResult(statusCode: 200,
                           etag: "x", lastModified: nil),
            HTTPHeadResult(statusCode: 200,
                           etag: "x", lastModified: nil),
        ])
        let earlyChecker = ZipETagUpdateChecker(
            prober: prober, clock: { self.fixedDate })
        let lateChecker = ZipETagUpdateChecker(
            prober: prober,
            clock: { self.fixedDate.addingTimeInterval(60) })
        let ref1 = try await earlyChecker.checkLatest(
            strategy: .zipETag(URL(string: "https://example/x.zip")!))
        let ref2 = try await lateChecker.checkLatest(
            strategy: .zipETag(URL(string: "https://example/x.zip")!))
        #expect(ref1 != ref2)   // fetchedAt differs
    }

    // MARK: - Composite integration

    @Test
    func compositeRoutesZipStrategyToZipChecker() async throws {
        // Composite holds a Git and a Zip checker. The git checker says
        // "not mine" for a zip strategy; the zip checker handles it.
        let zipProber = RecordingHeadProber(responses: [
            HTTPHeadResult(statusCode: 200,
                           etag: "abc", lastModified: nil)
        ])
        // Real GitRunner is irrelevant — Git checker bails on a zip
        // strategy before touching it. RecordingGitRunner is fine.
        let gitChecker = GitUpdateChecker(
            cacheRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("rc-\(UUID().uuidString)"),
            runner: RecordingGitRunner())
        let zipChecker = ZipETagUpdateChecker(
            prober: zipProber, clock: { self.fixedDate })
        let composite = CompositeUpdateChecker([gitChecker, zipChecker])

        let ref = try await composite.checkLatest(
            strategy: .zipETag(URL(string: "https://example/x.zip")!))
        #expect(ref == .zipETag(value: "abc", fetchedAt: fixedDate))
        #expect(zipProber.requested.count == 1)
    }
}
