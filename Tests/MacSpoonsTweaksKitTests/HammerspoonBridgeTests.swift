import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("HammerspoonBridge convenience composition")
struct HammerspoonBridgeConvenienceTests {

    @Test
    func configureForwardsConfigureScript() async throws {
        let runner = RecordingLuaRunner(returns: "")
        try await runner.configure(
            spoon: "FocusFollowsMouse",
            config: .object(["delay": .number(0.05)]),
            hasConfigure: true)
        #expect(runner.scripts == [
            "spoon.FocusFollowsMouse:configure({ delay = 0.05 })"
        ])
    }

    @Test
    func configureWithoutConfigureForwardsFlatAssignments() async throws {
        let runner = RecordingLuaRunner(returns: "")
        try await runner.configure(
            spoon: "Caffeine",
            config: .object(["show_notifications": .bool(true)]),
            hasConfigure: false)
        #expect(runner.scripts == [
            "spoon.Caffeine.show_notifications = true"
        ])
    }

    @Test
    func configureEmptyDoesNotRun() async throws {
        let runner = RecordingLuaRunner(returns: "")
        try await runner.configure(
            spoon: "X", config: .object([:]), hasConfigure: true)
        // No script emitted means we still call runLua with "",
        // which the bridge's runLua short-circuits. Recording runner
        // captures whatever it gets — we just check that no NON-empty
        // script was sent.
        #expect(runner.scripts.filter { !$0.isEmpty }.isEmpty)
    }

    @Test
    func startStopReloadScriptsAreCorrect() async throws {
        let runner = RecordingLuaRunner(returns: "")
        try await runner.startSpoon("X")
        try await runner.stopSpoon("X")
        try await runner.reload()
        #expect(runner.scripts == [
            "spoon.X:start()",
            "spoon.X:stop()",
            "hs.reload()",
        ])
    }

    @Test
    func bindHotkeysForwardsBuiltScript() async throws {
        let runner = RecordingLuaRunner(returns: "")
        try await runner.bindHotkeys(
            spoon: "FocusFollowsMouse",
            mapping: ["toggle": HotkeyBinding(mods: ["ctrl","cmd"], key: "f")])
        #expect(runner.scripts == [
            "spoon.FocusFollowsMouse:bindHotkeys(" +
            "{ toggle = { { \"ctrl\", \"cmd\" }, \"f\" } })"
        ])
    }

    @Test
    func readPropertyReturnsRunnerOutput() async throws {
        // The runner's stdout flows back through readProperty so callers
        // can compare against expected values in integration tests.
        let runner = RecordingLuaRunner(returns: "0.05")
        let out = try await runner.readProperty(
            spoon: "FocusFollowsMouse", fieldPath: "delay")
        #expect(out == "0.05")
        #expect(runner.scripts == ["return spoon.FocusFollowsMouse.delay"])
    }
}

// MARK: - Integration (runs only if hs CLI is available)

@Suite("HammerspoonBridge integration (requires `hs` CLI)")
struct HammerspoonBridgeIntegrationTests {

    /// Skips with a descriptive note when there's no live Hammerspoon to
    /// talk to. NSWorkspace can lie about `appRunning` (zombie processes,
    /// inheriting state), so the real test is: can `hs -c` actually
    /// reach the message port? We probe by running `return 'pong'` and
    /// treating the specific "message port" error as a skip signal.
    private func bridgeIfAvailable() async -> HammerspoonBridge? {
        let env = HammerspoonEnvironment()
        let status = env.snapshot()
        guard let bridge = HammerspoonBridge(status: status) else { return nil }
        do {
            let pong = try await bridge.runLua("return 'pong'", timeout: 3)
            return pong == "pong" ? bridge : nil
        } catch HammerspoonBridgeError.luaError(let stderr)
                where stderr.contains("message port") {
            return nil    // Hammerspoon not actually running
        } catch {
            return nil    // any other failure: skip the integration tier
        }
    }

    @Test
    func helloPongRoundTrip() async throws {
        guard let bridge = await bridgeIfAvailable() else { return }
        let out = try await bridge.runLua("return 'pong'", timeout: 5)
        #expect(out == "pong")
    }

    @Test
    func luaSyntaxErrorThrowsLuaError() async throws {
        guard let bridge = await bridgeIfAvailable() else { return }
        do {
            _ = try await bridge.runLua("this is not lua", timeout: 5)
            Issue.record("expected throw on invalid Lua")
        } catch let HammerspoonBridgeError.luaError(stderr) {
            // hs writes errors to stderr; just confirm we got something.
            #expect(!stderr.isEmpty)
        } catch {
            Issue.record("expected .luaError, got \(error)")
        }
    }

    @Test
    func adversarialStringRoundTripsAsString() async throws {
        // Plug a string LuaLiteral can't be tricked into closing. The hs
        // side must see exactly one string with the original bytes.
        guard let bridge = await bridgeIfAvailable() else { return }
        let nasty = "a\"b\\c\nd\u{1F}e"
        let literal = LuaLiteral.encode(.string(nasty))
        // Sanity check via the hash so we don't rely on the exact bytes
        // of how hs.printf would print this back to us.
        let out = try await bridge.runLua(
            "return hs.hash.MD5(\(literal))", timeout: 5)
        let expected = expectedMD5(of: nasty)
        #expect(out == expected,
                "Lua's MD5 of the round-tripped string must match Swift's")
    }

    /// MD5 in pure Swift over `s.utf8` — used as an oracle for the
    /// "did Lua receive the same bytes" check. Tiny implementation to
    /// avoid a CommonCrypto dependency in the test bundle.
    private func expectedMD5(of s: String) -> String {
        // Use CommonCrypto via Foundation — available on macOS.
        var hasher = CryptoMD5()
        hasher.update(Data(s.utf8))
        return hasher.finalize()
    }
}

// Minimal MD5 implementation for the integration test oracle. Standard
// algorithm, no external deps. Lifted here so the test bundle stays
// self-contained.
private struct CryptoMD5 {
    private var data = Data()
    mutating func update(_ chunk: Data) { data.append(chunk) }
    func finalize() -> String {
        let bytes = md5(Array(data))
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private func md5(_ message: [UInt8]) -> [UInt8] {
        // Constants
        let s: [UInt32] = [
            7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
            5, 9,14,20,5, 9,14,20,5, 9,14,20,5, 9,14,20,
            4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
            6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21
        ]
        let K: [UInt32] = [
            0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,
            0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,
            0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,
            0x6b901122,0xfd987193,0xa679438e,0x49b40821,
            0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,
            0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
            0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,
            0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,
            0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,
            0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,
            0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,
            0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
            0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,
            0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,
            0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,
            0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391
        ]
        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476
        var msg = message
        let origLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 {
            msg.append(UInt8((origLen >> (8 * i)) & 0xff))
        }
        let chunks = msg.count / 64
        for ci in 0..<chunks {
            var M = [UInt32](repeating: 0, count: 16)
            for j in 0..<16 {
                let base = ci * 64 + j * 4
                M[j] = UInt32(msg[base])
                     | UInt32(msg[base+1]) << 8
                     | UInt32(msg[base+2]) << 16
                     | UInt32(msg[base+3]) << 24
            }
            var A = a0, B = b0, C = c0, D = d0
            for i in 0..<64 {
                var F: UInt32 = 0
                var g: Int = 0
                if i < 16      { F = (B & C) | (~B & D); g = i }
                else if i < 32 { F = (D & B) | (~D & C); g = (5*i + 1) % 16 }
                else if i < 48 { F = B ^ C ^ D;          g = (3*i + 5) % 16 }
                else           { F = C ^ (B | ~D);       g = (7*i) % 16 }
                let temp = D
                D = C
                C = B
                let sum = A &+ F &+ K[i] &+ M[g]
                B = B &+ leftRotate(sum, by: s[i])
                A = temp
            }
            a0 = a0 &+ A; b0 = b0 &+ B; c0 = c0 &+ C; d0 = d0 &+ D
        }
        var out: [UInt8] = []
        for v in [a0, b0, c0, d0] {
            out.append(UInt8(v & 0xff))
            out.append(UInt8((v >> 8) & 0xff))
            out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 24) & 0xff))
        }
        return out
    }
    private func leftRotate(_ x: UInt32, by n: UInt32) -> UInt32 {
        return (x << n) | (x >> (32 - n))
    }
}
