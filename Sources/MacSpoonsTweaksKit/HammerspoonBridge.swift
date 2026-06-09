import Foundation

/// Anything that can execute a Lua script and return its stdout. Splits
/// the I/O surface from the convenience wrappers so tests can stand in
/// a recording mock without spawning a real `hs` process.
public protocol LuaRunner: Sendable {
    /// Run `script` and return its trimmed stdout. Throws on non-zero
    /// exit, process launch failure, or timeout.
    func runLua(_ script: String, timeout: TimeInterval) async throws -> String
}

/// LuaRunner that always throws `cliMissing`. Used as the orchestrator's
/// fallback when no live Hammerspoon is detected — persistence still
/// works, and Apply surfaces `liveAppliedOK == false` so the user knows
/// they need to reload Hammerspoon to pick up the snippet.
public struct NoOpLuaRunner: LuaRunner {
    public init() {}
    public func runLua(_ script: String, timeout: TimeInterval)
    async throws -> String {
        throw HammerspoonBridgeError.cliMissing
    }
}

/// All higher-level convenience methods compose `HammerspoonScript`
/// builders with `runLua`, so they live on the protocol — `RecordingLuaRunner`
/// and `HammerspoonBridge` pick them up identically.
public extension LuaRunner {

    func configure(
        spoon: String,
        config: ConfigValue,
        hasConfigure: Bool,
        timeout: TimeInterval = 5
    ) async throws {
        let script = HammerspoonScript.configure(
            spoon: spoon, config: config, hasConfigure: hasConfigure)
        _ = try await runLua(script, timeout: timeout)
    }

    func startSpoon(_ name: String,
                    timeout: TimeInterval = 5) async throws {
        _ = try await runLua(
            HammerspoonScript.startSpoon(name), timeout: timeout)
    }

    func stopSpoon(_ name: String,
                   timeout: TimeInterval = 5) async throws {
        _ = try await runLua(
            HammerspoonScript.stopSpoon(name), timeout: timeout)
    }

    func bindHotkeys(
        spoon: String,
        mapping: [String: HotkeyBinding],
        timeout: TimeInterval = 5
    ) async throws {
        _ = try await runLua(
            HammerspoonScript.bindHotkeys(spoon: spoon, mapping: mapping),
            timeout: timeout)
    }

    func reload(timeout: TimeInterval = 5) async throws {
        _ = try await runLua(
            HammerspoonScript.reload(), timeout: timeout)
    }

    /// `return spoon.<spoon>.<fieldPath>` — returns whatever Hammerspoon
    /// prints for the value. Used by Diagnostics and integration tests.
    func readProperty(
        spoon: String,
        fieldPath: String,
        timeout: TimeInterval = 5
    ) async throws -> String {
        return try await runLua(
            HammerspoonScript.readProperty(
                spoon: spoon, fieldPath: fieldPath),
            timeout: timeout)
    }
}

public enum HammerspoonBridgeError: Error, CustomStringConvertible {
    case cliMissing
    case processLaunchFailed(any Error)
    case luaError(stderr: String)
    case timeout

    public var description: String {
        switch self {
        case .cliMissing:
            return "Hammerspoon `hs` CLI not found. Enable it via " +
                   "Hammerspoon → Preferences → Install Command Line Tool."
        case .processLaunchFailed(let e):
            return "Failed to launch hs: \(e)"
        case .luaError(let stderr):
            return "Lua error: \(stderr)"
        case .timeout:
            return "Lua script timed out."
        }
    }
}

// MARK: - Production bridge

/// Drives the local Hammerspoon via its `hs -c` CLI. Pure I/O wrapper —
/// every Lua snippet it sends is built up-front by `HammerspoonScript`.
public final class HammerspoonBridge: LuaRunner, @unchecked Sendable {
    public let cliPath: URL

    public init(cliPath: URL) {
        self.cliPath = cliPath
    }

    /// Convenience initializer that pulls `cliPath` from a snapshot.
    /// Returns `nil` if the snapshot doesn't have a CLI — caller must
    /// surface the "enable command-line tool" UX.
    public convenience init?(status: HammerspoonStatus) {
        guard let cli = status.cliPath else { return nil }
        self.init(cliPath: cli)
    }

    public func runLua(_ script: String, timeout: TimeInterval = 5)
    async throws -> String {
        // Empty scripts short-circuit so callers can blindly forward
        // builder output like `HammerspoonScript.bindHotkeys(...)` even
        // when the builder produced nothing.
        if script.isEmpty { return "" }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = cliPath
            // -c runs a single Lua expression. Passing `script` as a
            // discrete argument keeps the shell out of the equation —
            // there's no interpolation surface for the script's bytes.
            process.arguments = ["-c", script]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError  = stderr

            // The continuation must resume exactly once across the
            // termination handler, the launch path, and the timeout
            // kill. A simple lock + flag suffices since contention is
            // bounded to those three call sites.
            let lock     = NSLock()
            var resumed  = false
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
                    let msg = errStr.isEmpty
                        ? "exit \(p.terminationStatus): \(outStr)" : errStr
                    resumeOnce(.failure(
                        HammerspoonBridgeError.luaError(stderr: msg)))
                } else {
                    resumeOnce(.success(outStr.trimmingCharacters(
                        in: .whitespacesAndNewlines)))
                }
            }

            do {
                try process.run()
            } catch {
                resumeOnce(.failure(
                    HammerspoonBridgeError.processLaunchFailed(error)))
                return
            }

            // Timeout watchdog. Sleeps off-actor; if it wakes before the
            // process has finished, SIGTERMs the process and resumes
            // with .timeout. The terminationHandler that fires shortly
            // after will see `resumed == true` and no-op.
            Task.detached {
                try? await Task.sleep(
                    nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                    resumeOnce(.failure(HammerspoonBridgeError.timeout))
                }
            }
        }
    }

    // Convenience methods (configure / startSpoon / etc.) come from the
    // LuaRunner protocol extension above.
}

// MARK: - Recording runner (test helper)

/// Records every script handed to it and returns a fixed stdout. Lets
/// tests assert that the bridge's convenience methods compose builders
/// correctly without spawning processes.
public final class RecordingLuaRunner: LuaRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _scripts: [String] = []
    private var nextOutput: String

    public init(returns output: String = "") {
        self.nextOutput = output
    }

    public var scripts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _scripts
    }

    public func runLua(_ script: String, timeout: TimeInterval)
    async throws -> String {
        lock.lock()
        _scripts.append(script)
        let out = nextOutput
        lock.unlock()
        return out
    }
}
