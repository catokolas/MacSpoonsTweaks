# Distribution

How to build a release `.app` bundle of MacSpoonsTweaks. No Apple
Developer account involved — the build is ad-hoc signed and recipients
right-click → Open the first time.

Everything goes through `tools/build-app.sh`.

## TL;DR

```sh
# Personal use — runs on YOUR Mac after one right-click → Open.
./tools/build-app.sh                      # default: ad-hoc signed

# Share the .app with someone — same workflow, recipient does the
# right-click → Open dance once.
./tools/build-app.sh
ls build/MacSpoonsTweaks-*.zip            # hand them the zip
```

`build/` is gitignored; rebuilds are clean each time.

## Sign modes

### Ad-hoc signed (default)

```sh
./tools/build-app.sh
```

Self-signature with `codesign --sign -`. Hardened runtime still on,
bundle is tamper-evident. Recipients see "app from an unidentified
developer" the first time — they **right-click → Open** (or System
Settings → Privacy & Security → "Open Anyway"), and macOS remembers
the choice from then on.

### Unsigned

```sh
./tools/build-app.sh --skip-sign
```

Plain `.app` with no signature at all. Same Gatekeeper warning as
ad-hoc, plus the bundle isn't tamper-evident. Useful only as a
sanity-check on the build — no real reason to share an unsigned
bundle when ad-hoc is one flag away.

## Configure

Versions and bundle ID come from env vars or `tools/.env`
(gitignored):

```sh
# tools/.env (optional)
BUNDLE_ID="dev.cato.MacSpoonsTweaks"
```

Defaults if unset:
- `BUNDLE_ID = dev.local.MacSpoonsTweaks`
- `VERSION` = latest `v*` git tag with the `v` stripped, falling back
  to `0.1.0` if there's no tag
- `BUILD` = `git rev-list --count HEAD`

Override on the command line for one-off versions:

```sh
VERSION=0.3.0-rc1 ./tools/build-app.sh
```

## What the recipient does

The first-launch workflow depends on macOS version. Apple removed
the easy "right-click → Open" path in macOS Sequoia (15) and Tahoe
(26) — those versions require an explicit allowlist click in
System Settings.

### macOS Sonoma (14) and earlier

1. Double-click → "Cannot be opened because it is from an
   unidentified developer." Close the dialog.
2. **Right-click → Open** (or two-finger click → Open). The same
   dialog reappears but now with an **Open** button.
3. Click Open. macOS remembers the trust decision; the app launches
   normally on every subsequent double-click.

### macOS Sequoia (15) and Tahoe (26+)

1. Double-click → "MacSpoonsTweaks Not Opened — Apple could not
   verify…" Click **Done** (don't pick *Move to Trash* — it deletes
   the app).
2. Open **System Settings → Privacy & Security**.
3. Scroll to the bottom: *"MacSpoonsTweaks was blocked from use…"*
   Click **Open Anyway**, authenticate with Touch ID / password.
4. The original dialog reopens with an **Open** button. Click it.
5. macOS now trusts the bundle; subsequent launches just work.

Faster alternative via Terminal, works on every version:

```sh
sudo xattr -dr com.apple.quarantine /Applications/MacSpoonsTweaks.app
open /Applications/MacSpoonsTweaks.app
```

Strips the quarantine xattr macOS attaches to anything from outside
the Mac App Store. Homebrew is supposed to strip this on
`brew install --cask`, but recent macOS sometimes re-adds it on the
first launch attempt.

Walk friends through it once; most have done some variant of this for
other indie Mac apps.

## Cut a release

The whole flow, copy-pasteable:

```sh
# 1. Pick a version (semver, no leading "v").
VERSION=0.3.0

# 2. Tag and push. tools/build-app.sh reads `git describe --tags`,
#    so tagging BEFORE building is what makes the bundle's
#    CFBundleShortVersionString line up with the release name.
git tag v$VERSION
git push origin v$VERSION

# 3. Build the ad-hoc-signed bundle + companion zip. Produces:
#      build/MacSpoonsTweaks.app
#      build/MacSpoonsTweaks-$VERSION.zip
./tools/build-app.sh

# Make a note of the checksum - needed by Homebrew later
shasum -a 256 build/MacSpoonsTweaks-0.1.0.zip

# 4. Publish the release on GitHub and attach the zip.
gh release create v$VERSION \
  build/MacSpoonsTweaks-$VERSION.zip \
  --title "v$VERSION" \
  --notes "MacSpoonsTweaks v$VERSION. Ad-hoc signed — first launch needs right-click → Open."
```

That creates the GitHub release page, drafts release notes, and uploads
the zip as a downloadable asset. The README's
`https://github.com/catokolas/MacSpoonsTweaks/releases` link resolves
to whatever the most recent tag points at.

### Drafting before publishing

If you want to review the release page before it goes live, add
`--draft` to the `gh release create` line, eyeball it in the web UI,
then click *Publish release* (or `gh release edit v$VERSION --draft=false`).

### Pre-release / RC builds

Versions with a hyphen suffix (`0.3.0-rc1`, `0.3.0-beta.2`) bypass the
git tag — pass them on the command line and skip the tag step entirely:

```sh
VERSION=0.3.0-rc1 ./tools/build-app.sh
gh release create v0.3.0-rc1 \
  build/MacSpoonsTweaks-0.3.0-rc1.zip \
  --title "v0.3.0-rc1" --notes "Release candidate." --prerelease
```

## Publish a Homebrew tap

Once at least one release has landed on GitHub, a personal Homebrew
tap makes `brew install --cask catokolas/tap/macspoonstweaks` work —
no submission to homebrew-core required (and `homebrew-core` would
reject this anyway: ad-hoc signed builds don't meet their notarization
bar).

### One-time setup

A tap is just a public GitHub repo whose name starts with
`homebrew-`. The bit after the prefix becomes the tap shortname.

```sh
gh repo create catokolas/homebrew-tap --public --clone \
    --description "Homebrew tap for catokolas's macOS tools"
cd homebrew-tap
mkdir Casks
```

That makes the tap reachable as `catokolas/tap` (Homebrew strips the
`homebrew-` prefix automatically).

### Add the cask

For each release you want available via brew, you maintain one
`Casks/macspoonstweaks.rb` file in that tap repo. The first version:

```ruby
cask "macspoonstweaks" do
  version "0.1.0"
  sha256 "<paste shasum -a 256 of the release zip here>"

  url "https://github.com/catokolas/MacSpoonsTweaks/releases/download/v#{version}/MacSpoonsTweaks-#{version}.zip"
  name "MacSpoonsTweaks"
  desc "SwiftUI companion for Hammerspoon Spoons"
  homepage "https://github.com/catokolas/MacSpoonsTweaks"

  depends_on cask: "hammerspoon"
  depends_on macos: :sonoma

  app "MacSpoonsTweaks.app"

  zap trash: [
    "~/Library/Application Support/MacSpoonsTweaks",
    "~/Library/Caches/MacSpoonsTweaks",
  ]
end
```

Notes on the stanzas:

- **`depends_on cask: "hammerspoon"`** — Homebrew installs Hammerspoon
  automatically if it isn't already present.
- **`depends_on macos: :sonoma`** — mirrors the macOS 14 floor
  declared in `Package.swift`.
- **`zap trash: […]`** — what `brew uninstall --zap` removes alongside
  the `.app`. Add any extra dirs the app accumulates as features land
  (e.g. `~/Library/Preferences/dev.local.MacSpoonsTweaks.plist` once
  macOS writes one).
- **No `auto_updates true`** — the app has no Sparkle, so Homebrew
  itself is the update channel (`brew upgrade --cask macspoonstweaks`).

### Bump per release

Each new MacSpoonsTweaks release requires the cask's `version` and
`sha256` to change. After running the "Cut a release" recipe above:

```sh
# In the MacSpoonsTweaks repo, right after `gh release create …`:
NEW_SHA=$(shasum -a 256 build/MacSpoonsTweaks-$VERSION.zip | cut -d' ' -f1)
echo "new sha: $NEW_SHA"

# Then in catokolas/homebrew-tap, edit Casks/macspoonstweaks.rb:
#   - replace `version "..."` with the new VERSION
#   - replace `sha256 "..."` with $NEW_SHA
# and commit + push.
```

You can automate this from the MacSpoonsTweaks release workflow with
[`dawidd6/action-homebrew-bump-formula`](https://github.com/dawidd6/action-homebrew-bump-formula),
which opens a PR to the tap. Not worth wiring up until release cadence
gets boring — manual edit is ~60 seconds.

### Verify the cask before users see it

From any Mac:

```sh
# Pre-flight audit (catches Ruby syntax errors, missing fields, dead
# URLs). DO NOT pass `--new` or `--strict` — they enforce
# homebrew-cask SUBMISSION rules a personal tap with an ad-hoc signed
# app can't satisfy:
#   * "GitHub repository not notable enough" (needs 75+ stars)
#   * "Signature verification failed" (needs Apple notarization)
# Both are expected for this distribution path and don't block install.
brew audit --cask catokolas/tap/macspoonstweaks

# Real install — bundles into /Applications.
brew install --cask catokolas/tap/macspoonstweaks

# First launch: macOS may flag the unsigned bundle on Sonoma+. Tell
# users right-click → Open. Homebrew strips com.apple.quarantine, so
# the "App is damaged" red dialog usually doesn't appear via brew.

# Cleanup test:
brew uninstall --cask --zap macspoonstweaks
```

### Gotchas

- **Ad-hoc signing**: Homebrew accepts ad-hoc signed casks, but users
  may still get a "macOS cannot verify the developer" dialog on first
  launch. Mention right-click → Open in the release notes.
- **Quarantine**: `brew install --cask` removes the quarantine xattr,
  so the worst-case "App is damaged" red dialog doesn't appear via
  brew. Direct-download users still need the `xattr -dr` trick
  documented under Troubleshooting below.
- **Cask name lowercase**: the filename and the `cask "..."` token must
  be lowercase. The display name in `name "MacSpoonsTweaks"` can stay
  CamelCase.

## Troubleshooting

### "App is damaged and can't be opened" (in red)

Quarantine flag stuck — common if the zip came from email or a
browser that aggressively quarantines. Clear it:

```sh
xattr -dr com.apple.quarantine /path/to/MacSpoonsTweaks.app
```

Then right-click → Open as usual.

### Codesign fails with `AMFIUnserializeXML: syntax error`

Some XML feature in `tools/Entitlements.plist` that Apple's strict
plist parser doesn't accept. Keep that file empty (`<dict/>` only,
no XML comments inside the dict). The explanatory comments live in
`tools/README.md` instead.

### Build script can't find executable

The script looks under `.build/apple/Products/Release/` (universal
build) and falls back to `.build/release/`. If both miss, your
`swift build -c release` either failed silently or produced a path
neither location matches — run the build manually and inspect.

## Future polish

- **DMG instead of zip**: `create-dmg` from Homebrew. Cosmetic.
- **App icon**: drop `MacSpoonsTweaks.icns` into `tools/Resources/`
  (gitignored), have `build-app.sh` copy it into the bundle's
  Resources dir, and reference `AppIcon` from Info.plist via
  `CFBundleIconFile`.
