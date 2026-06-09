import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("Manifest decoding")
struct ManifestDecodeTests {

    @Test
    func decodesAllSixSpoonsFromFixture() throws {
        let catalog = try decodeFixture()
        #expect(catalog.schemaVersion == 1)
        #expect(catalog.repo == "catokolas/HS_SpoonsContrib")
        #expect(catalog.spoons.count == 6)
        #expect(Set(catalog.spoons.map(\.name)) == [
            "FocusFollowsMouse", "MouseCopyPasteSelection",
            "MouseScrollTweaks",  "MouseTrackpadTweaks",
            "MoveSpaces",         "SpotifyPlayPause",
        ])
    }

    @Test
    func focusFollowsMouseScalarFields() throws {
        let ffm = try spoon(named: "FocusFollowsMouse")
        #expect(ffm.version == "0.1")
        #expect(ffm.lifecycle.hasStart)
        #expect(ffm.lifecycle.hasConfigure)
        #expect(!ffm.lifecycle.eventDriven)

        let delay = try unwrap(ffm, key: "delay")
        guard case .number(let n) = delay else {
            Issue.record("expected .number, got \(delay)")
            return
        }
        #expect(n.default == 0.1)
        #expect(n.min == 0)
        #expect(n.max == 2)
        #expect(n.step == 0.01)
        #expect(n.unit == "s")

        let excluded = try unwrap(ffm, key: "excludedApps")
        guard case .stringList(let sl) = excluded else {
            Issue.record("expected .stringList, got \(excluded)")
            return
        }
        #expect(sl.default == [])
    }

    @Test
    func spotifyPlayPauseStringListAndIntDefaults() throws {
        let spotify = try spoon(named: "SpotifyPlayPause")
        #expect(spotify.lifecycle.eventDriven)
        #expect(spotify.hotkeys.isEmpty)

        let pref = try unwrap(spotify, key: "preferredDevices")
        guard case .stringList(let sl) = pref else {
            Issue.record("expected .stringList, got \(pref)")
            return
        }
        #expect(sl.default ==
                ["usb audio", "airpods", "Headphone", "plantronics", "jabra"])

        let hours = try unwrap(spotify, key: "pauseHoursOptions")
        guard case .int(let i) = hours else {
            Issue.record("expected .int, got \(hours)")
            return
        }
        #expect(i.default == 4)
    }

    @Test
    func mouseTrackpadTweaksRecursiveObjectDecodes() throws {
        let mtt = try spoon(named: "MouseTrackpadTweaks")
        let mc = try unwrap(mtt, key: "middleClick")
        guard case .object(let mcObj) = mc else {
            Issue.record("expected .object for middleClick, got \(mc)")
            return
        }
        // Top-level enabled bool.
        guard case .bool(let b)? = mcObj.fields.first(where: { $0.key == "enabled" }) else {
            Issue.record("middleClick.enabled missing")
            return
        }
        #expect(b.default == true)

        // Nested int: middleClick.multiFinger.fingerCount = 3 [2..5]
        guard case .object(let mfObj)? =
                mcObj.fields.first(where: { $0.key == "multiFinger" }) else {
            Issue.record("multiFinger sub-object missing")
            return
        }
        guard case .int(let fc)? =
                mfObj.fields.first(where: { $0.key == "fingerCount" }) else {
            Issue.record("fingerCount int missing")
            return
        }
        #expect(fc.default == 3)
        #expect(fc.min == 2)
        #expect(fc.max == 5)

        // Deep nested bool: middleClick.topCenter.devices.magicMouse = true
        guard case .object(let tcObj)? =
                mcObj.fields.first(where: { $0.key == "topCenter" }) else {
            Issue.record("topCenter missing")
            return
        }
        guard case .object(let devObj)? =
                tcObj.fields.first(where: { $0.key == "devices" }) else {
            Issue.record("devices missing")
            return
        }
        guard case .bool(let mb)? =
                devObj.fields.first(where: { $0.key == "magicMouse" }) else {
            Issue.record("magicMouse bool missing")
            return
        }
        #expect(mb.default == true)
    }

    @Test
    func mouseTrackpadTweaksHotkeyActions() throws {
        let mtt = try spoon(named: "MouseTrackpadTweaks")
        let actions = mtt.hotkeys.map(\.action).sorted()
        #expect(actions == ["toggle", "toggleInvertScroll", "toggleMiddleClick"])
    }

    @Test
    func moveSpacesNoConfigureAndPairedHotkeys() throws {
        let ms = try spoon(named: "MoveSpaces")
        #expect(!ms.lifecycle.hasConfigure)
        #expect(!ms.lifecycle.hasStart)
        let actions = ms.hotkeys.map(\.action).sorted()
        #expect(actions == ["space_left", "space_right"])
    }

    @Test
    func enumFieldRoundTripsInsideMouseTrackpadTweaks() throws {
        let mtt = try spoon(named: "MouseTrackpadTweaks")
        guard case .object(let mc)? =
                mtt.config.first(where: { $0.key == "middleClick" }) else {
            Issue.record("middleClick missing")
            return
        }
        guard case .object(let mf)? =
                mc.fields.first(where: { $0.key == "multiFinger" }) else {
            Issue.record("multiFinger missing")
            return
        }
        guard case .enumChoice(let e)? =
                mf.fields.first(where: { $0.key == "trigger" }) else {
            Issue.record("trigger enum missing")
            return
        }
        #expect(e.default == "either")
        #expect(Set(e.enum.map(\.value)) == ["tap", "click", "either"])
    }

    @Test
    func configValueLuaLiteralRoundTrip() throws {
        // .luaLiteral persists as {"__luaLiteral": "..."} and decodes back
        // to .luaLiteral (not .object). Other .object cases pass through.
        let original = ConfigValue.luaLiteral("{1, 2, 3}")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConfigValue.self, from: data)
        #expect(decoded == original)

        let plain = ConfigValue.object(["a": .int(1), "b": .string("x")])
        let plainData = try JSONEncoder().encode(plain)
        let plainDecoded = try JSONDecoder().decode(ConfigValue.self, from: plainData)
        #expect(plainDecoded == plain)
    }

    // MARK: helpers

    private func decodeFixture() throws -> SpoonsCatalog {
        let url = try #require(Bundle.module.url(
            forResource: "spoons", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SpoonsCatalog.self, from: data)
    }

    private func spoon(named name: String) throws -> SpoonManifest {
        let catalog = try decodeFixture()
        return try #require(catalog.spoons.first(where: { $0.name == name }),
                            "Spoon \(name) missing from fixture")
    }

    private func unwrap(_ s: SpoonManifest, key: String) throws -> ConfigField {
        return try #require(s.config.first(where: { $0.key == key }),
                            "\(s.name) missing field \(key)")
    }
}
