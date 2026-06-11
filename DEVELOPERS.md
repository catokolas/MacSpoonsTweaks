# Developer notes

Internals and contributor orientation for MacSpoonsTweaks. End-user
install instructions live in [README.md](README.md); this file is the
"how does it actually work and how do I hack on it" companion.

## What it is

SwiftUI macOS app that fetches Hammerspoon Spoons from two catalogs and
manages them via three artifacts:

1. **`~/Library/Application Support/MacSpoonsTweaks/state.json`** —
   which Spoons the user enabled, their config + hotkey overrides,
   installed version refs, active/deactivated state, and installed companion native
   modules.
2. **`~/.hammerspoon/mac_spoons_tweaks.lua`** — a managed file
   regenerated on every Apply. One `spoon.SpoonInstall:andUse(name, {…})`
   block per enabled Spoon. `init.lua` `require`s it.
3. **Live `hs -c …` round-trips** — config + hotkey changes are pushed
   to the running Hammerspoon so the user doesn't need to reload.

Install / load / configure / start / hotkey-bind is delegated at
runtime to [`SpoonInstall.spoon`](https://www.hammerspoon.org/Spoons/SpoonInstall.html)
(which the app bootstraps on first launch).

## Layout

Two SPM targets:

- `Sources/MacSpoonsTweaksKit/` — pure data + I/O layer, no SwiftUI.
  Catalog sources, the Hammerspoon bridge, the SpoonInstall installer,
  the snippet generator, update checkers, hotkey/conflict/drift
  detectors, the apply orchestrator, the GitHub releases client + the
  optional-native-modules installer. **Everything testable lives
  here.**
- `Sources/MacSpoonsTweaks/` — SwiftUI `@main` app. `MacSpoonsTweaksApp`
  builds the `SpoonCatalogModel` (the one place the bridge, installers,
  orchestrator, and update checker are constructed). `Views/` contains
  the shell, per-Spoon detail panel, the optional-modules section, the
  MenuBarExtra, and the form widgets under `Views/Fields/`.

Plus `tools/` (release build script + `Info.plist.template`) and
[`Distribution.md`](Distribution.md) (no-Apple-account release runbook).

## Build / test

CommandLineTools doesn't ship Swift Testing or XCTest, so point the
CLI at Xcode's toolchain:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test
```

(Or `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
to make it the default.)

Test suite is ≈250 Swift Testing cases across the Kit; one
`LuaValidator` integration suite is flaky when Hammerspoon isn't
running — those tests probe with `hs -c "return 'pong'"` and bail
gracefully, but if Hammerspoon crashed mid-run they'll fail until
relaunch.

## Run the app

Three ways, ordered by use case:

1. **Xcode** (recommended for development)

   ```sh
   open Package.swift
   ```

   Cmd-R to launch. Incremental rebuilds, breakpoints, and SwiftUI
   previews (open any `Views/*.swift` and the canvas works). This is
   the only setup where SwiftUI previews work.

2. **`swift run`** (CLI smoke test)

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
       swift run -c release MacSpoonsTweaks
   ```

   Launches from Terminal as a child process. Useful for "does it
   crash on launch?" sanity checks, but **TextField input is
   unreliable** because the binary isn't a real bundle (no Info.plist,
   no proper foreground-app activation). Don't use this for UX
   testing.

3. **Real `.app` bundle**

   ```sh
   ./tools/build-app.sh
   open build/MacSpoonsTweaks.app
   ```

   Ad-hoc signed Mac app under `build/`. Dock icon, menu bar, Cmd-Tab,
   keyboard input — all work like a normal app. First launch needs
   right-click → Open → Open to clear Gatekeeper.

   See [Distribution.md](Distribution.md) for the full **Cut a release**
   recipe (`git tag` → `tools/build-app.sh` → `gh release create`).

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
- **A new optional native module declaration.** Add an
  `optionalModules` entry on the relevant Spoon's `spoon-manifest.json`
  in `HS_SpoonsContrib`; `NativeModuleInstaller` will pick it up via
  the catalog refresh.

## Conventions

- **Every Kit file has a sibling test file** under
  `Tests/MacSpoonsTweaksKitTests/`. Swift Testing (`import Testing`,
  `@Test`, `#expect`), not XCTest.
- **Integration tests skip cleanly** when no live `hs` CLI is reachable
  — they probe with `hs -c "return 'pong'"` and bail if it errors out
  with the "message port" string. Don't fail CI when Hammerspoon
  isn't running.
- **Bridge calls go through `LuaRunner`**, never `Process` directly.
  That keeps `RecordingLuaRunner` / `BridgeRecorder` able to see
  everything. The orchestrator falls back to `NoOpLuaRunner` when no
  `hs` CLI is present — Apply still persists.
- **No auto-commit.** Commits happen only when explicitly asked for.
  Multi-line commit messages with embedded apostrophes or quotes:
  write to `/tmp/foo.txt` and `git commit -F` — heredocs choke on
  the combination.
- **Distribution.** Ad-hoc signed only (`tools/build-app.sh` defaults
  to `codesign --sign -`). No Apple Developer account, no
  notarization, no Sparkle. Recipients right-click → Open the first
  time and macOS remembers. See `Distribution.md` for the release
  recipe.

## Compatible catalog format

The *Manage catalogs…* sheet lets users add any GitHub repo that
publishes a `spoons.json` matching the schema MacSpoonsTweaks already
consumes. The repo is expected at
`https://raw.githubusercontent.com/<owner>/<repo>/<branch>/spoons.json`
and must serialize as:

```json
{
  "schemaVersion": 1,
  "repo":   "owner/repo",
  "spoons": [ /* one SpoonManifest object per Spoon */ ],
  "overrides": { /* optional, ignored for user catalogs */ }
}
```

Each `SpoonManifest` carries the same fields as catokolas's:
`schemaVersion`, `name`, `version`, `description`, `author`,
`homepage`, `license`, `lifecycle`, `config`, `hotkeys`, plus the
optional `optionalModules` and `knownIssues` arrays. The canonical
build script is `HS_SpoonsContrib/tools/build-manifest.lua` — fork
that workflow rather than hand-authoring the JSON.

The Spoons themselves are fetched via SpoonInstall at user-install
time, so each `<Name>.spoon/` directory must exist at the same git
ref the catalog declares (SpoonInstall does a shallow clone). User
catalogs get registered with SpoonInstall as
`spoon.SpoonInstall.repos["user:<owner>/<repo>"] = { url, branch, … }`
in the generated snippet, and their `andUse(name, { repo = "user:…", … })`
blocks resolve against that.

The override-of-upstream mechanism is **catokolas-only** by
convention. User catalogs that try to ship an `overrides` block will
have it silently ignored — third parties shouldn't rewrite each
other's manifests.

## Sibling repo

[`HS_SpoonsContrib`](https://github.com/catokolas/HS_SpoonsContrib)
carries the Spoons + the manifests this app consumes. Changes there
that affect the typed catalog (new config fields, manifest schema
edits, new `optionalModules` declarations) want a coordinated update
in either the test fixture
(`Tests/MacSpoonsTweaksKitTests/Fixtures/spoons.json`) or the live
fetch path. See `HS_SpoonsContrib/CLAUDE.md` for the manifest-vs-
init.lua keep-in-sync invariant (CI's `validate-manifest.lua` enforces
it on every PR).
