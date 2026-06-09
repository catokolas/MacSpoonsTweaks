import Foundation

/// Executes a git command and returns its stdout. Tests stand in a
/// recording mock that asserts the args our update checker sends —
/// without spawning real `git` processes.
public protocol GitRunner: Sendable {
    /// `git <args...>` (optionally `git -C <cwd> ...` via the `cwd`
    /// argument). Returns trimmed stdout; throws on non-zero exit or
    /// process launch failure.
    func run(args: [String], cwd: URL?) async throws -> String
}

public enum GitRunnerError: Error, CustomStringConvertible {
    case gitNotFound
    case processLaunchFailed(any Error)
    case commandFailed(args: [String], stderr: String, exitCode: Int32)

    public var description: String {
        switch self {
        case .gitNotFound:
            return "git not found. Install Xcode Command Line Tools."
        case .processLaunchFailed(let e):
            return "Failed to launch git: \(e)"
        case .commandFailed(let args, let stderr, let code):
            return "git \(args.joined(separator: " ")) exited \(code): \(stderr)"
        }
    }
}

// MARK: - System impl

public struct SystemGitRunner: GitRunner {

    public let gitPath: URL

    /// Default initializer probes the two locations git ships at on a
    /// Mac dev machine: `/usr/bin/git` (CommandLineTools) and
    /// `/opt/homebrew/bin/git` (Homebrew on Apple Silicon). Falls back
    /// to whichever exists. Throws if neither is present.
    public init(gitPath: URL? = nil) throws {
        if let explicit = gitPath {
            self.gitPath = explicit
            return
        }
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git",
                          "/usr/local/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                self.gitPath = URL(fileURLWithPath: candidate)
                return
            }
        }
        throw GitRunnerError.gitNotFound
    }

    public func run(args: [String], cwd: URL? = nil) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = gitPath
            process.arguments = args
            if let cwd = cwd {
                process.currentDirectoryURL = cwd
            }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError  = stderr

            let lock = NSLock()
            var resumed = false
            func resumeOnce(_ result: Result<String, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let s): continuation.resume(returning: s)
                case .failure(let e): continuation.resume(throwing: e)
                }
            }

            process.terminationHandler = { p in
                let outData = (try? stdout.fileHandleForReading.readToEnd())
                                ?? Data()
                let errData = (try? stderr.fileHandleForReading.readToEnd())
                                ?? Data()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                if p.terminationStatus != 0 {
                    resumeOnce(.failure(GitRunnerError.commandFailed(
                        args: args,
                        stderr: errStr.isEmpty ? outStr : errStr,
                        exitCode: p.terminationStatus)))
                } else {
                    resumeOnce(.success(outStr.trimmingCharacters(
                        in: .whitespacesAndNewlines)))
                }
            }

            do {
                try process.run()
            } catch {
                resumeOnce(.failure(GitRunnerError.processLaunchFailed(error)))
            }
        }
    }
}

// MARK: - Recording mock (test helper)

/// Records every call and returns a configurable canned stdout per
/// invocation. Lets tests assert the exact git args our update checker
/// produces without spawning processes.
public final class RecordingGitRunner: GitRunner, @unchecked Sendable {

    public struct Call: Equatable, Sendable {
        public let args: [String]
        public let cwd:  URL?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var outputs: [String]
    private var errorToThrow: (any Error)?

    public init(outputs: [String] = []) {
        self.outputs = outputs
    }

    public var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    public func throwOnNextCall(_ error: any Error) {
        lock.lock(); defer { lock.unlock() }
        errorToThrow = error
    }

    public func run(args: [String], cwd: URL?) async throws -> String {
        lock.lock()
        _calls.append(Call(args: args, cwd: cwd))
        if let err = errorToThrow {
            errorToThrow = nil
            lock.unlock()
            throw err
        }
        let out = outputs.isEmpty ? "" : outputs.removeFirst()
        lock.unlock()
        return out
    }
}
