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

1. Xcode (recommended for development)

  cd ~/git/MacSpoonsTweaks
  open Package.swift

  Xcode opens, treats the package as a project. Top toolbar:
  - Scheme selector → MacSpoonsTweaks
  - Build target → My Mac

  Then ⌘R. App launches, you get incremental rebuilds, the SwiftUI canvas works in any
   view file, breakpoints work.

  This is the only setup where SwiftUI previews work — pop open SpoonDetailView.swift
  and click "Resume" in the canvas to live-preview the detail panel without launching
  the app.

  2. swift run from CLI (quick smoke test)

  cd ~/git/MacSpoonsTweaks
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run -c release MacSpoonsTweaks

  Launches the app from Terminal. Works, but it runs as a Terminal subprocess: no
  proper Dock icon, no Cmd-Tab presence, no menu bar. Fine for "does it crash on
  launch?" sanity checks. Ctrl-C in Terminal quits it.

  The DEVELOPER_DIR prefix is the same SDK detail the README documents —
  CommandLineTools doesn't ship SwiftUI for this kind of build.

  3. Build a real .app bundle

  cd ~/git/MacSpoonsTweaks
  ./tools/build-app.sh        # default: ad-hoc signed
  open build/MacSpoonsTweaks.app

  Produces a proper Mac app under build/ that behaves like any other app — Dock icon,
  menu bar, Cmd-Tab, the works. First double-click may show a Gatekeeper "unidentified
   developer" dialog because of ad-hoc signing; right-click the app → Open → Open
  clears it and macOS remembers.

  This is what you'd hand to a friend.

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
