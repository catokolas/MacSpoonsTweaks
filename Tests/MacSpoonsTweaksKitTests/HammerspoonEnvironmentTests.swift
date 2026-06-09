import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("HammerspoonEnvironment")
struct HammerspoonEnvironmentTests {

    /// Probe whose responses are entirely driven by injected state. Lets
    /// us assert the environment's behavior independent of the host's
    /// real Hammerspoon install.
    struct MockProbe: HammerspoonProbe {
        var appInstalled = false
        var appRunning   = false
        var cliPath:     URL? = nil
        var existing:    Set<String> = []
        var homeDirectory: URL = URL(fileURLWithPath: "/Users/test")

        func isAppInstalled() -> Bool { appInstalled }
        func isAppRunning()   -> Bool { appRunning }
        func findCLIPath()    -> URL? { cliPath }
        func fileExists(at url: URL) -> Bool { existing.contains(url.path) }
    }

    @Test
    func snapshotReflectsPaths() {
        let env = HammerspoonEnvironment(probe: MockProbe(
            homeDirectory: URL(fileURLWithPath: "/Users/test")))
        let s = env.snapshot()
        #expect(s.configDir.path   == "/Users/test/.hammerspoon")
        #expect(s.spoonsDir.path   == "/Users/test/.hammerspoon/Spoons")
        #expect(s.initLuaPath.path == "/Users/test/.hammerspoon/init.lua")
    }

    @Test
    func cleanMachineShowsNothingInstalled() {
        let env = HammerspoonEnvironment(probe: MockProbe())
        let s = env.snapshot()
        #expect(!s.appInstalled)
        #expect(!s.appRunning)
        #expect(s.cliPath == nil)
        #expect(!s.spoonInstallPresent)
        #expect(!s.canRunLua)
    }

    @Test
    func fullyConfiguredMachineReportsCanRunLua() {
        let cli = URL(fileURLWithPath: "/opt/homebrew/bin/hs")
        let env = HammerspoonEnvironment(probe: MockProbe(
            appInstalled: true, appRunning: true, cliPath: cli))
        let s = env.snapshot()
        #expect(s.appInstalled)
        #expect(s.appRunning)
        #expect(s.cliPath == cli)
        #expect(s.canRunLua, "running + CLI present must imply canRunLua")
    }

    @Test
    func canRunLuaRequiresBothRunningAndCLI() {
        // Installed but not running.
        var probe = MockProbe(
            appInstalled: true,
            appRunning:   false,
            cliPath:      URL(fileURLWithPath: "/opt/homebrew/bin/hs"))
        #expect(!HammerspoonEnvironment(probe: probe).snapshot().canRunLua)
        // Running but no CLI.
        probe = MockProbe(
            appInstalled: true,
            appRunning:   true,
            cliPath:      nil)
        #expect(!HammerspoonEnvironment(probe: probe).snapshot().canRunLua)
    }

    @Test
    func spoonInstallPresenceDetectedAtCorrectPath() {
        // We probe for the init.lua, not just the directory — matches
        // how the bootstrap checks "did the unzip succeed?".
        let probe = MockProbe(
            existing: ["/Users/test/.hammerspoon/Spoons/SpoonInstall.spoon/init.lua"])
        let env = HammerspoonEnvironment(probe: probe)
        #expect(env.snapshot().spoonInstallPresent)
    }

    @Test
    func spoonInstallNotPresentWhenOnlyDirectoryExists() {
        // A dangling SpoonInstall.spoon dir without init.lua means a
        // botched bootstrap — must not be treated as present.
        let probe = MockProbe(
            existing: ["/Users/test/.hammerspoon/Spoons/SpoonInstall.spoon"])
        let env = HammerspoonEnvironment(probe: probe)
        #expect(!env.snapshot().spoonInstallPresent)
    }
}
