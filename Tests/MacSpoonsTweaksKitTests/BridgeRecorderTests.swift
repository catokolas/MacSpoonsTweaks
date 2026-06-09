import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("BridgeRecorder")
struct BridgeRecorderTests {

    /// LuaRunner that returns canned outputs in order, or throws a
    /// canned error once per call.
    final class Scripted: LuaRunner, @unchecked Sendable {
        let lock = NSLock()
        var outputs: [String]
        var errors:  [(any Error)?]

        init(outputs: [String] = [], errors: [(any Error)?] = []) {
            self.outputs = outputs
            self.errors  = errors
        }

        func runLua(_ script: String, timeout: TimeInterval)
        async throws -> String {
            lock.lock(); defer { lock.unlock() }
            if !errors.isEmpty, let e = errors.removeFirst() {
                throw e
            }
            return outputs.isEmpty ? "" : outputs.removeFirst()
        }
    }

    // MARK: - Recording

    @Test
    func successesAreRecordedWithStdout() async throws {
        let inner = Scripted(outputs: ["pong"])
        let recorder = BridgeRecorder(wrapping: inner)
        let result = try await recorder.runLua("return 'pong'", timeout: 1)
        #expect(result == "pong")

        let history = recorder.recent()
        #expect(history.count == 1)
        #expect(history[0].script == "return 'pong'")
        if case .success(let out) = history[0].result {
            #expect(out == "pong")
        } else {
            Issue.record("expected .success, got \(history[0].result)")
        }
    }

    @Test
    func failuresAreRecordedAndStillThrow() async throws {
        let inner = Scripted(errors: [
            HammerspoonBridgeError.luaError(stderr: "syntax")
        ])
        let recorder = BridgeRecorder(wrapping: inner)
        do {
            _ = try await recorder.runLua("garbage", timeout: 1)
            Issue.record("expected throw")
        } catch HammerspoonBridgeError.luaError {
            // expected
        } catch {
            Issue.record("wrong error: \(error)")
        }

        let history = recorder.recent()
        #expect(history.count == 1)
        if case .failure(let msg) = history[0].result {
            #expect(msg.contains("Lua error"))
        } else {
            Issue.record("expected .failure")
        }
    }

    // MARK: - Ring buffer

    @Test
    func ringBufferEvictsOldestPastCapacity() async throws {
        let inner = Scripted(outputs: Array(repeating: "ok", count: 10))
        let recorder = BridgeRecorder(wrapping: inner, capacity: 3)
        for i in 0..<10 {
            _ = try await recorder.runLua("call-\(i)", timeout: 1)
        }
        let history = recorder.recent()
        #expect(history.count == 3, "should have evicted to capacity")
        // The three surviving scripts should be the last three.
        #expect(history.map(\.script) == ["call-7", "call-8", "call-9"])
    }

    @Test
    func clearResetsBuffer() async throws {
        let inner = Scripted(outputs: ["a", "b"])
        let recorder = BridgeRecorder(wrapping: inner)
        _ = try await recorder.runLua("1", timeout: 1)
        _ = try await recorder.runLua("2", timeout: 1)
        #expect(recorder.recent().count == 2)
        recorder.clear()
        #expect(recorder.recent().isEmpty)
    }

    // MARK: - Callback

    @Test
    func onRecordCallbackFiresForEveryInvocation() async throws {
        // Strong-locked storage so the callback (which runs from the
        // recorder's caller) can safely write into it.
        actor Capture {
            var seen: [BridgeInvocation] = []
            func add(_ x: BridgeInvocation) { seen.append(x) }
        }
        let capture = Capture()

        let inner = Scripted(
            outputs: ["a", ""],
            errors:  [nil,
                      HammerspoonBridgeError.luaError(stderr: "boom")])
        let recorder = BridgeRecorder(
            wrapping: inner,
            onRecord: { inv in
                // Capture from a Sendable closure.
                Task { await capture.add(inv) }
            })

        _ = try await recorder.runLua("ok", timeout: 1)
        do {
            _ = try await recorder.runLua("err", timeout: 1)
        } catch {
            // expected — runLua propagates the error after recording it
        }

        // Let the dispatched captures land. A tiny sleep is fine here
        // since the test's outer Task is what enqueued them.
        try await Task.sleep(nanoseconds: 50_000_000)
        let seen = await capture.seen
        #expect(seen.count == 2)
        #expect(seen[0].result.isSuccess)
        #expect(!seen[1].result.isSuccess)
    }
}
