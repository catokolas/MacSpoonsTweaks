import Foundation
import Testing
@testable import MacSpoonsTweaksKit

@Suite("CatokolasSource overrides exposure")
struct CatokolasSourceOverridesTests {

    @Test
    func decodeCapturesOverridesBlockForLaterRetrieval() throws {
        // Minimal hand-crafted spoons.json with an overrides entry.
        // The exposure path (decode → overridesForUpstream) is the one
        // HammerspoonOfficialSource's view-model orchestrator hits.
        let json = """
        {
          "schemaVersion": 1,
          "repo": "catokolas/HS_SpoonsContrib",
          "spoons": [],
          "overrides": {
            "Caffeine": {
              "schemaVersion": 1,
              "name": "Caffeine",
              "version": "1.0",
              "description": "Curated description.",
              "lifecycle": {
                "hasStart": true, "hasStop": true,
                "hasToggle": true, "hasConfigure": false,
                "eventDriven": false
              },
              "config": [
                {
                  "key": "show_notifications",
                  "label": "Show notifications",
                  "type": "bool",
                  "default": true
                }
              ],
              "hotkeys": [
                {
                  "action": "toggle",
                  "label": "Toggle",
                  "default": { "mods": ["ctrl","alt","cmd"], "key": "k" }
                }
              ]
            }
          }
        }
        """
        let source = CatokolasSource()
        _ = try source.decode(Data(json.utf8))

        let overrides = source.overridesForUpstream
        let caffeine = try #require(overrides["Caffeine"])
        #expect(caffeine.name == "Caffeine")
        #expect(caffeine.description == "Curated description.")
        #expect(caffeine.config.count == 1)
        #expect(caffeine.config[0].key == "show_notifications")
        #expect(caffeine.hotkeys.count == 1)
    }

    @Test
    func overridesForUpstreamStartsEmpty() {
        let source = CatokolasSource()
        #expect(source.overridesForUpstream.isEmpty)
    }

    @Test
    func defaultExtensionGivesEmptyOverridesForOtherSources() {
        let source = HammerspoonOfficialSource()
        #expect(source.overridesForUpstream.isEmpty,
                "HammerspoonOfficialSource shouldn't claim to carry overrides")
    }
}
