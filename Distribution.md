# Distribution

How to build a release `.app` bundle of MacSpoonsTweaks for yourself
and for the occasional friend, **without an Apple Developer account**.
The paid Developer ID + notarization path is sketched at the end for
completeness.

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

## Three modes

### 1. Ad-hoc signed (default)

```sh
./tools/build-app.sh
```

Self-signature with `codesign --sign -`. No Apple account needed,
hardened runtime still on, bundle is tamper-evident. Recipients see
"app from an unidentified developer" the first time — they
**right-click → Open** (or System Settings → Privacy & Security →
"Open Anyway"), and macOS remembers the choice from then on.

Drop-in for sharing with people who trust you and know the workflow.

### 2. Unsigned

```sh
./tools/build-app.sh --skip-sign
```

Plain `.app` with no signature at all. Same Gatekeeper warning as
ad-hoc, plus the bundle isn't tamper-evident. Useful only as a
sanity-check on the build — no real reason to share an unsigned
bundle when ad-hoc is one flag away.

### 3. Developer ID + notarized

```sh
./tools/build-app.sh --notarize
```

Requires the paid path; see "If you ever decide to pay Apple" below.
Produces a fully-stapled `.app` that runs cleanly on anyone's machine
with no Gatekeeper override.

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
  to `0.0.0` if there's no tag
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

## Release workflow

For a versioned release you want to keep around:

1. Decide on a version (semver, e.g. `0.3.0`).
2. Update the README / CHANGELOG.
3. `git tag v0.3.0 && git push --tags`.
4. `./tools/build-app.sh`.
5. (Optional) `gh release create v0.3.0 build/MacSpoonsTweaks-0.3.0.zip`.

Step 4 picks up the tag automatically.

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

## If you ever decide to pay Apple

The Developer ID path is $99/yr. It buys you:
- Notarization (Apple scans your build and the user gets a real
  green-check launch, no Gatekeeper override needed)
- The ability to embed a real signing identity instead of `adhoc`,
  which makes update-style "did this binary change?" checks more
  meaningful

Setup (do once):

1. **Cert.** Join the Apple Developer Program. In Xcode → Settings →
   Accounts → your Apple ID → Manage Certificates → **+** →
   "Developer ID Application". Confirm with
   `security find-identity -v -p codesigning`.
2. **App-specific password.** At
   <https://account.apple.com/account/manage/section/security>, under
   "App-Specific Passwords", create one labeled e.g.
   `MacSpoonsTweaks-notarize`.
3. **notarytool credentials.**
   ```sh
   xcrun notarytool store-credentials "MacSpoonsTweaks-notarize" \
       --apple-id "you@example.com" \
       --team-id  "XXXXXXXXXX" \
       --password "xxxx-xxxx-xxxx-xxxx"
   ```
4. **tools/.env:**
   ```sh
   CODESIGN_IDENTITY="Developer ID Application: Your Name (XXXXXXXXXX)"
   NOTARYTOOL_PROFILE="MacSpoonsTweaks-notarize"
   ```

Then `./tools/build-app.sh --notarize` produces a stapled, gatekeeper-
approved bundle.

## Future polish

- **Sparkle auto-updates**: out of scope for ad-hoc; would need real
  Developer ID anyway for the "is this update tampered with?" check
  to be meaningful.
- **DMG instead of zip**: `create-dmg` from Homebrew. Cosmetic.
- **App icon**: drop `MacSpoonsTweaks.icns` into `tools/Resources/`
  (gitignored), have `build-app.sh` copy it into the bundle's
  Resources dir, and reference `AppIcon` from Info.plist via
  `CFBundleIconFile`.
