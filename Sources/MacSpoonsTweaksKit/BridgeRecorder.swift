import Foundation

/// One row in the bridge's invocation history. Captured by
/// `BridgeRecorder` and rendered by `DiagnosticsView`.
public struct BridgeInvocation: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let script: String
    public let durationSeconds: Double
    public let result: Result

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        script: String,
        durationSeconds: Double,
        result: Result
    ) {
        self.id = id
        self.timestamp = timestamp
        self.script = script
        self.durationSeconds = durationSeconds
        self.result = result
    }

    public enum Result: Sendable, Equatable {
        case success(stdout: String)
        case failure(message: String)

        public var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }
}

/// Wraps a `LuaRunner` so every call goes into a ring buffer of the
/// most recent N invocations. The buffer is locked for thread safety;
/// `recent()` returns a snapshot copy. Optionally calls `onRecord` for
/// each invocation so the SwiftUI side can publish updates.
///
/// The wrapper is transparent — it forwards `runLua` exactly, including
/// throwing the underlying error after recording it.
public final class BridgeRecorder: LuaRunner, @unchecked Sendable {

    public let inner: any LuaRunner
    public let capacity: Int

    private let lock = NSLock()
    private var buffer: [BridgeInvocation] = []
    /// Settable so consumers that need a `self`-capturing closure can
    /// install it post-init. Reads/writes lock-guarded.
    private var _onRecord: (@Sendable (BridgeInvocation) -> Void)?

    public init(
        wrapping inner: any LuaRunner,
        capacity: Int = 50,
        onRecord: (@Sendable (BridgeInvocation) -> Void)? = nil
    ) {
        self.inner    = inner
        self.capacity = max(1, capacity)
        self._onRecord = onRecord
    }

    /// Replace the onRecord callback. Useful when the caller needs a
    /// `self`-capturing observer that can't be set at init time.
    public func setObserver(
        _ callback: (@Sendable (BridgeInvocation) -> Void)?
    ) {
        lock.lock(); defer { lock.unlock() }
        self._onRecord = callback
    }

    // MARK: LuaRunner

    public func runLua(_ script: String, timeout: TimeInterval)
    async throws -> String {
        let started = Date()
        do {
            let out = try await inner.runLua(script, timeout: timeout)
            record(BridgeInvocation(
                timestamp:       started,
                script:          script,
                durationSeconds: Date().timeIntervalSince(started),
                result:          .success(stdout: out)))
            return out
        } catch {
            record(BridgeInvocation(
                timestamp:       started,
                script:          script,
                durationSeconds: Date().timeIntervalSince(started),
                result:          .failure(message:
                    String(describing: error))))
            throw error
        }
    }

    // MARK: Snapshot / control

    /// Snapshot copy of the buffer, oldest-first. UI sorts to taste.
    public func recent() -> [BridgeInvocation] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll()
    }

    // MARK: Internals

    private func record(_ inv: BridgeInvocation) {
        lock.lock()
        buffer.append(inv)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        let observer = _onRecord
        lock.unlock()
        observer?(inv)
    }
}
