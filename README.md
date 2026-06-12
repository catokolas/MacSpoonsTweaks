# MacSpoonsTweaks

[![Release](https://img.shields.io/github/v/release/catokolas/MacSpoonsTweaks?sort=semver)](https://github.com/catokolas/MacSpoonsTweaks/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/catokolas/MacSpoonsTweaks/total)](https://github.com/catokolas/MacSpoonsTweaks/releases)
[![macOS](https://img.shields.io/badge/macOS-14%2B-blue)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

A small SwiftUI companion for [Hammerspoon](https://www.hammerspoon.org).
Browse, install, and configure
[Spoons](https://www.hammerspoon.org/Spoons/) — Hammerspoon's plugin
format — through typed forms and a menu bar shortcut, without
hand-editing `~/.hammerspoon/init.lua`.

![MacSpoonsTweaks — sidebar listing every Spoon, detail view editing a selected one](app-example.png)

Pairs naturally with
[`catokolas/HS_SpoonsContrib`](https://github.com/catokolas/HS_SpoonsContrib)
(curated Spoons + optional native helpers) and the official
[`Hammerspoon/Spoons`](https://github.com/Hammerspoon/Spoons) catalog.

## Requirements

- **macOS 14** (Sonoma) or newer
- **Hammerspoon** installed:

  ```sh
  brew install --cask hammerspoon
  ```

  (Or download the `.app` from
  [hammerspoon.org](https://www.hammerspoon.org).) Launch it once so it
  registers itself.

That's it. MacSpoonsTweaks drives Hammerspoon through its bundled `hs`
command-line tool, which Homebrew symlinks automatically. If you
installed Hammerspoon by dragging the `.app` and the app can't reach
it, open the Hammerspoon console and run `hs.ipc.cliInstall()` once.

## Install

### Homebrew *(recommended, coming soon)*

A Homebrew cask is in preparation. Once published:

```sh
brew install --cask catokolas/tap/macspoonstweaks
```

### Download the latest release

Grab `MacSpoonsTweaks-x.y.z.zip` from
[Releases](https://github.com/catokolas/MacSpoonsTweaks/releases), unzip
it, and drag `MacSpoonsTweaks.app` into `/Applications`.

The build is ad-hoc signed, so the first launch needs **right-click →
Open → Open**. macOS remembers after that.

### Build from source

If you have Xcode 16+:

```sh
git clone https://github.com/catokolas/MacSpoonsTweaks.git
cd MacSpoonsTweaks
./tools/build-app.sh
open build/MacSpoonsTweaks.app
```

See [DEVELOPERS.md](DEVELOPERS.md) for the full developer setup.

## First run

1. Launch MacSpoonsTweaks. Look for the puzzle-piece icon in the menu
   bar.
2. The sidebar lists every Spoon in the two catalogs (catokolas + the
   official Hammerspoon collection). Pick one.
3. Click **Install**. The app fetches the Spoon and asks you (via a
   banner) to patch your `init.lua` so it loads the generated snippet.
4. Edit the typed config form to taste, set hotkeys with the recorder,
   and click **Apply**. State is saved, the snippet at
   `~/.hammerspoon/mac_spoons_tweaks.lua` is regenerated, and the
   change is pushed live to the running Hammerspoon.
5. From the menu bar's *Active Spoons ▶* submenu you can activate /
   deactivate any installed Spoon without opening the window.

## License

MIT.
