# tools/

Build + signing scaffolding for MacSpoonsTweaks. See `Distribution.md`
in the repo root for the full runbook.

## Files

- `build-app.sh` — builds a universal release `.app` bundle. Default
  is ad-hoc signed; flags switch to unsigned / Developer-ID-notarized.
- `Info.plist.template` — `{{BUNDLE_ID}}` / `{{VERSION}}` / `{{BUILD}}`
  placeholders substituted at build time.
- `Entitlements.plist` — empty `<dict/>`. The app runs **unsandboxed**
  by choice: we need `Process` access to `git`, `hs`, and `unzip`,
  which the sandbox forbids. The hardened runtime (enabled via
  `codesign --options runtime`) is what notarization actually
  requires, and it works without any entitlements for our use case.

  > Note: the entitlements file must be strict-empty XML (`<dict/>`,
  > no comments inside the dict) — Apple's `AMFIUnserializeXML`
  > parser used by `codesign` rejects XML comments inside `<dict>`
  > even though `plutil` accepts them.

  If we ever ship a Mac App Store build (would require XPC instead of
  `Process`), copy this file to `Entitlements-sandboxed.plist` and add
  the `com.apple.security.app-sandbox` entitlement plus the necessary
  temporary exceptions, then pass `--entitlements` to `codesign`.

## .env

`build-app.sh` reads `tools/.env` for repo-local defaults — currently
just the Developer ID / notarytool stuff that only applies if you're
going through the paid Apple Developer path. The file is gitignored;
see `Distribution.md` for what to put in it.
