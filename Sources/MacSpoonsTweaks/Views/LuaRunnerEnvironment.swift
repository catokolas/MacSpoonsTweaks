import SwiftUI
import MacSpoonsTweaksKit

/// SwiftUI environment slot for the active `LuaRunner`. Fields that
/// need live validation (currently `LuaLiteralEditor`) read this and
/// degrade gracefully to "no Hammerspoon connection" when it's nil.
private struct LuaRunnerKey: EnvironmentKey {
    static let defaultValue: (any LuaRunner)? = nil
}

extension EnvironmentValues {
    var luaRunner: (any LuaRunner)? {
        get { self[LuaRunnerKey.self] }
        set { self[LuaRunnerKey.self] = newValue }
    }
}

extension View {
    /// Inject a `LuaRunner` into the environment so descendant fields
    /// can validate Lua expressions against it. Pass `nil` to make
    /// validation a no-op (chip stays neutral).
    func luaRunner(_ runner: (any LuaRunner)?) -> some View {
        environment(\.luaRunner, runner)
    }
}
