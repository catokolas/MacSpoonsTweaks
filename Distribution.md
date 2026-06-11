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

When someone you share the ad-hoc zip with double-clicks it:

1. macOS unzips to `MacSpoonsTweaks.app`.
2. Double-click → "Cannot be opened because it is from an
   unidentified developer." Close the dialog.
3. **Right-click → Open** (or two-finger click → Open). The same
   dialog reappears but now with an **Open** button.
4. Click Open. macOS remembers the trust decision; the app launches
   normally on every subsequent double-click.

That's it. Walk friends through it once; most have done it before for
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
