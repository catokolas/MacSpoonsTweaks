# MacSpoonsTweaks

Native macOS app that installs and configures Hammerspoon Spoons from
[`catokolas/HS_SpoonsContrib`](https://github.com/catokolas/HS_SpoonsContrib)
and the official [`Hammerspoon/Spoons`](https://github.com/Hammerspoon/Spoons)
catalog. Install / load / configure / start is delegated at runtime to
[`SpoonInstall.spoon`](https://www.hammerspoon.org/Spoons/SpoonInstall.html);
the app writes a managed `~/.hammerspoon/mac_spoons_tweaks.lua` snippet
(a series of `spoon.SpoonInstall:andUse(name, {...})` blocks) and applies
config changes live via `hs -c`.

See `~/.claude/plans/plan-how-to-make-glowing-tarjan.md` for the full
implementation plan.

## Layout

```
Package.swift                                 # SPM, macOS 14+, Swift 5.10+
Sources/
├── MacSpoonsTweaksKit/                       # pure-data layer, CLI-testable
│   ├── ConfigValue.swift                     # typed value tree (Codable)
│   ├── Manifest.swift                        # spoons.json decode model
│   ├── CatalogSource.swift                   # protocol + SpoonCatalogEntry
│   └── CatokolasSource.swift                 # ETag-cached fetcher for catokolas
└── MacSpoonsTweaks/                          # SwiftUI @main app, depends on Kit
    ├── MacSpoonsTweaksApp.swift              # @main + SpoonCatalogModel (ObservableObject)
    └── Views/ContentView.swift               # NavigationSplitView stub
Tests/MacSpoonsTweaksKitTests/
├── ManifestDecodeTests.swift                 # Swift Testing (`import Testing`)
└── Fixtures/spoons.json                      # pinned copy of HS_SpoonsContrib/spoons.json
```

## Build / test from CLI

The CommandLineTools toolchain doesn't ship XCTest / Swift Testing, so
point the Swift CLI at Xcode's toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Or `xcode-select -s` to make Xcode the default and drop the env var.

## Running the app

Open `Package.swift` in Xcode and press Run. (`swift run MacSpoonsTweaks`
from CLI works but Mac-app affordances — menu bar, dock activation —
come up cleaner from Xcode.)

The app fetches `https://raw.githubusercontent.com/catokolas/HS_SpoonsContrib/main/spoons.json`
on launch and lists the six Spoons in the sidebar. Selecting one shows
a stub detail panel listing the schema. The full config UI, hotkey
recorder, install/update/remove, snippet generation, and SpoonInstall
bootstrap are still to come — see the plan file for sequencing.

## Status

Phase 2 (skeleton + Source 1) is in place:

- ✅ SPM project (`MacSpoonsTweaksKit` library + `MacSpoonsTweaks` executable)
- ✅ Full data model (`SpoonsCatalog` / `SpoonManifest` / `ConfigField`
  discriminated union with recursive `object` support)
- ✅ `ConfigValue` typed tree with JSON round-trip
- ✅ `CatalogSource` protocol + `CatokolasSource` (URLSession + ETag
  caching, falls back to disk cache offline)
- ✅ Minimal SwiftUI shell (NavigationSplitView, sidebar, detail stub)
- ✅ 8 decode tests passing against the real `spoons.json` fixture

Next: `LuaLiteral` + `HammerspoonBridge` (phase 3 of the plan) — the
foundational pieces every later phase depends on.
