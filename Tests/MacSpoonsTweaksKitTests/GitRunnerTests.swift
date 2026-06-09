import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("GitRunner")
struct GitRunnerTests {

    @Test
    func systemGitRunnerLocatesAvailableBinary() throws {
        // CI machines and developer machines both have git somewhere;
        // we just need to confirm SystemGitRunner finds one of the
        // standard locations.
        let runner = try SystemGitRunner()
        let path = runner.gitPath.path
        #expect(["/usr/bin/git", "/opt/homebrew/bin/git",
                 "/usr/local/bin/git"].contains(path),
                "expected a standard git path, got \(path)")
    }

    @Test
    func systemGitRunnerVersionRoundTrip() async throws {
        let runner = try SystemGitRunner()
        let out = try await runner.run(args: ["--version"], cwd: nil)
        #expect(out.hasPrefix("git version "),
                "unexpected output: \(out)")
    }

    @Test
    func systemGitRunnerThrowsOnFailedCommand() async throws {
        let runner = try SystemGitRunner()
        do {
            _ = try await runner.run(
                args: ["this-is-not-a-real-subcommand"], cwd: nil)
            Issue.record("expected throw for bogus subcommand")
        } catch let GitRunnerError.commandFailed(args, stderr, code) {
            #expect(args == ["this-is-not-a-real-subcommand"])
            #expect(code != 0)
            #expect(!stderr.isEmpty)
        } catch {
            Issue.record("expected .commandFailed, got \(error)")
        }
    }

    @Test
    func explicitPathBypassesProbing() throws {
        // When the caller supplies an explicit path, we don't probe —
        // even if the path doesn't exist. Lets the SwiftUI layer respect
        // user-configured git locations later.
        let runner = try SystemGitRunner(
            gitPath: URL(fileURLWithPath: "/nonexistent/git"))
        #expect(runner.gitPath.path == "/nonexistent/git")
    }

    // MARK: - Recording mock

    @Test
    func recordingRunnerCapturesAllArgsAndCwds() async throws {
        let runner = RecordingGitRunner(outputs: ["", "out2"])
        _ = try await runner.run(
            args: ["status"], cwd: URL(fileURLWithPath: "/tmp/a"))
        _ = try await runner.run(args: ["log"], cwd: nil)
        let calls = runner.calls
        #expect(calls.count == 2)
        #expect(calls[0] == .init(
            args: ["status"], cwd: URL(fileURLWithPath: "/tmp/a")))
        #expect(calls[1] == .init(args: ["log"], cwd: nil))
    }

    @Test
    func recordingRunnerSurfacesInjectedErrors() async throws {
        let runner = RecordingGitRunner()
        runner.throwOnNextCall(GitRunnerError.gitNotFound)
        do {
            _ = try await runner.run(args: ["fetch"], cwd: nil)
            Issue.record("expected throw")
        } catch GitRunnerError.gitNotFound {
            // expected
        } catch {
            Issue.record("wrong error: \(error)")
        }
        // After the throwing call, the call IS still recorded.
        #expect(runner.calls.count == 1)
    }
}
