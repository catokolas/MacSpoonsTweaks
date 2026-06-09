import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("SpoonInstallScript builders")
struct SpoonInstallScriptTests {

    @Test
    func ensureLoadedIsIdempotentGuard() {
        // `hs.loadSpoon` is itself idempotent but emits console output
        // every call. The conditional keeps the log noise down.
        #expect(SpoonInstallScript.ensureLoaded ==
                "if not spoon.SpoonInstall then hs.loadSpoon(\"SpoonInstall\") end")
    }

    @Test
    func registerRepoEmitsAllFields() {
        let script = SpoonInstallScript.registerRepo(
            id: "catokolas",
            url: "https://github.com/catokolas/HS_SpoonsContrib",
            branch: "main",
            desc: "Cato's Spoons")
        #expect(script ==
            "spoon.SpoonInstall.repos[\"catokolas\"] = " +
            "{ branch = \"main\", desc = \"Cato's Spoons\", " +
            "url = \"https://github.com/catokolas/HS_SpoonsContrib\" }")
    }

    @Test
    func registerRepoOmitsDescWhenNil() {
        let script = SpoonInstallScript.registerRepo(
            id: "x", url: "https://example", branch: "main", desc: nil)
        #expect(!script.contains("desc"))
        #expect(script.contains("branch = \"main\""))
        #expect(script.contains("url = \"https://example\""))
    }

    @Test
    func updateRepoQuotesArgument() {
        #expect(SpoonInstallScript.updateRepo(id: "catokolas")
                == "spoon.SpoonInstall:updateRepo(\"catokolas\")")
    }

    @Test
    func installFromRepoReturnsCanonicalOutcome() {
        // The "ok"/"fail" strings are the bridge's contract: the Swift
        // side checks runLua's stdout exactly. Plain ` ok ` semantics
        // (truthy vs nil) wouldn't survive the stringification.
        let script = SpoonInstallScript.installFromRepo(
            name: "FocusFollowsMouse", repoID: "catokolas")
        #expect(script ==
            "spoon.SpoonInstall.use_syncinstall = true\n" +
            "local ok = spoon.SpoonInstall:installSpoonFromRepo(" +
                "\"FocusFollowsMouse\", \"catokolas\")\n" +
            "return ok and \"ok\" or \"fail\"")
    }

    @Test
    func installComposesLoadRegisterUpdateInstall() {
        let script = SpoonInstallScript.install(
            name: "FocusFollowsMouse",
            repo: .custom(
                id: "catokolas",
                url: "https://github.com/catokolas/HS_SpoonsContrib",
                branch: "main",
                desc: "Cato's Spoons"))
        // Sanity-check the order — load before register before update
        // before install — by looking for each substring's position.
        let loadIdx     = script.range(of: "loadSpoon(\"SpoonInstall\")")?.lowerBound
        let registerIdx = script.range(of: "spoon.SpoonInstall.repos[\"catokolas\"]")?.lowerBound
        let updateIdx   = script.range(of: ":updateRepo(\"catokolas\")")?.lowerBound
        let installIdx  = script.range(of: ":installSpoonFromRepo(\"FocusFollowsMouse\"")?.lowerBound

        #expect(loadIdx != nil)
        #expect(registerIdx != nil)
        #expect(updateIdx != nil)
        #expect(installIdx != nil)
        #expect(loadIdx! < registerIdx!)
        #expect(registerIdx! < updateIdx!)
        #expect(updateIdx! < installIdx!)
    }

    @Test
    func installAgainstDefaultRepoSkipsRegistration() {
        // The official "default" repo is built into SpoonInstall — we
        // must NOT overwrite its url/branch entry on every install.
        let script = SpoonInstallScript.install(
            name: "Caffeine", repo: .default)
        #expect(!script.contains("spoon.SpoonInstall.repos["),
                "registerRepo should be skipped for .default repos")
        #expect(script.contains(":updateRepo(\"default\")"))
        #expect(script.contains(
            ":installSpoonFromRepo(\"Caffeine\", \"default\")"))
    }

    @Test
    func unloadStopsAndClearsNamespace() {
        let script = SpoonInstallScript.unload(name: "FocusFollowsMouse")
        #expect(script.contains(
            "if spoon.FocusFollowsMouse and spoon.FocusFollowsMouse.stop then"))
        #expect(script.contains("spoon.FocusFollowsMouse:stop()"))
        #expect(script.contains("spoon.FocusFollowsMouse = nil"))
        // Package.loaded is cleared via BOTH the "spoon.X" and plain "X"
        // keys — Hammerspoon uses the prefixed form, but some
        // hand-authored Spoons require() themselves under the plain name.
        #expect(script.contains(
            "package.loaded[\"spoon.FocusFollowsMouse\"] = nil"))
        #expect(script.contains(
            "package.loaded[\"FocusFollowsMouse\"] = nil"))
    }
}
