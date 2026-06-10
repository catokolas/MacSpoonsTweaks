# Repo notes for Claude / agents

SwiftUI macOS app that installs and configures Hammerspoon Spoons —
the GUI companion to the `HS_SpoonsContrib` repo at
`/Users/cato/git/HS_SpoonsContrib`. Reads that repo's published
`spoons.json` over HTTPS to render typed config forms, drives install
+ live apply through the `hs` CLI and `SpoonInstall.spoon`.

The full implementation plan lives at
`~/.claude/plans/plan-how-to-make-glowing-tarjan.md`.

## Quick start

```sh
# Run + test from the CLI (CommandLineTools doesn't ship Swift Testing
# or XCTest — point at Xcode's toolchain or `xcode-select -s ...`):
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test          # 228 tests across 28 suites at last commit

# Run in Xcode (also where SwiftUI previews work):
open Package.swift

# Build a real .app bundle for personal use / sharing:
./tools/build-app.sh                 # ad-hoc signed, no Apple account needed
open build/MacSpoonsTweaks.app
```

## Layout

Two SPM targets:

- `Sources/MacSpoonsTweaksKit/` — pure data + I/O layer, no SwiftUI.
  Catalog sources, the Hammerspoon bridge, the installer, the snippet
  generator, update checkers, hotkey + conflict + drift detectors,
  the apply orchestrator. **Everything testable lives here.**
- `Sources/MacSpoonsTweaks/` — SwiftUI `@main` app. `MacSpoonsTweaksApp.swift`
  builds the `SpoonCatalogModel` (the one place the bridge / installer
  / orchestrator / update checker are constructed). `Views/` contains
  the shell + per-Spoon panels; `Views/Fields/` the form widgets.

Plus `tools/` (release build script + Info.plist template) and
`Distribution.md` (no-Apple-account release runbook).

## Where to add things

- **New catalog source.** Implement `CatalogSource` in Kit, wire it
  into `SpoonCatalogModel.refresh()`. Each source exposes its own
  `updateCheckStrategy(for:)` to pick git vs zip-ETag detection.
- **New ConfigField type.** Add a case to `ConfigField`, a field
  struct, a SwiftUI view under `Views/Fields/`, a binding adapter in
  `BindingAdapters.swift`, and a dispatch case in `ConfigFormView`.
- **New live action.** Pure script builder in `HammerspoonScript.swift`
  or `SpoonInstallScript.swift`, then a convenience method on
  `LuaRunner` (protocol extension) so `RecordingLuaRunner` picks it
  up for tests.
- **Anything user-facing on Apply.** `SpoonOrchestrator.apply` is the
  funnel — persist + regenerate snippet + push live, in that order.
  Don't bypass it from views.

## Conventions

- **Every Kit file has a sibling test file** in
  `Tests/MacSpoonsTweaksKitTests/`. Swift Testing (`import Testing`,
  `@Test`, `#expect`) is used throughout — not XCTest.
- **Integration tests skip cleanly** when no live `hs` CLI is reachable
  — they probe with `hs -c "return 'pong'"` and bail if it errors out
  with the "message port" string. Don't fail CI when Hammerspoon
  isn't running.
- **Bridge calls go through `LuaRunner`**, never `Process` directly.
  That keeps `RecordingLuaRunner` / `BridgeRecorder` able to see
  everything. The orchestrator falls back to `NoOpLuaRunner` when no
  `hs` CLI is present — Apply still persists.
- **No auto-commit.** Commits happen only when the user asks.
  Multi-line commit messages with embedded apostrophes or quotes:
  write to `/tmp/foo.txt` and `git commit -F` — heredocs choke on
  the combination.
- **Distribution.** This is a private initiative; no paid Apple
  Developer Program membership. `tools/build-app.sh` defaults to
  ad-hoc signing. Don't propose Developer ID / notarization /
  Sparkle as the primary path — Developer ID is documented in
  `Distribution.md` as a future option only.

## Sibling repo

`HS_SpoonsContrib` (parent dir of this clone) carries the Spoons + the
manifests this app consumes. Changes there that affect the typed
catalog (new config fields, manifest schema edits) want a coordinated
update in either the test fixture
(`Tests/MacSpoonsTweaksKitTests/Fixtures/spoons.json`) or the live
fetch path. See `HS_SpoonsContrib/CLAUDE.md` for the manifest-vs-init.lua
keep-in-sync invariant.
