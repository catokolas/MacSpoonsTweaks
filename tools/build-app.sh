#!/usr/bin/env bash
# tools/build-app.sh
#
# Build a universal release .app bundle of MacSpoonsTweaks. Three
# signing modes from most to least permissive:
#
#   --adhoc-sign         self-signature (no Apple account required) —
#                        default; runs on the build machine; other
#                        users get a Gatekeeper warning + right-click
#                        → Open workflow
#   --skip-sign          no codesign at all; useful only as a quick
#                        build sanity check
#   --notarize           full Developer ID + Apple notarization +
#                        staple. Requires a paid Apple Developer
#                        account; see Distribution.md
#
# Configure via environment variables OR a tools/.env file:
#
#   BUNDLE_ID             reverse-DNS bundle identifier
#                         default: dev.local.MacSpoonsTweaks
#   VERSION               marketing version string (e.g. 0.1.0)
#                         default: derived from `git describe --tags`
#   BUILD                 monotonic build number
#                         default: `git rev-list --count HEAD`
#   CODESIGN_IDENTITY     Developer ID identity, e.g.
#                         "Developer ID Application: Cato Kolås (XXXXXXXXXX)"
#                         required for --notarize
#   NOTARYTOOL_PROFILE    keychain profile created via `notarytool
#                         store-credentials <profile>`
#                         required for --notarize
#
# Usage:
#   tools/build-app.sh                 # build + ad-hoc sign (default)
#   tools/build-app.sh --skip-sign     # build only, leave .app unsigned
#   tools/build-app.sh --notarize      # build + Developer ID sign + notarize
#
# Outputs:
#   build/MacSpoonsTweaks.app
#   build/MacSpoonsTweaks-<VERSION>.zip      (signed builds)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Pick up env overrides from tools/.env if present (gitignored).
if [[ -f tools/.env ]]; then
  # shellcheck disable=SC1091
  source tools/.env
fi

# Defaults.
BUNDLE_ID="${BUNDLE_ID:-dev.local.MacSpoonsTweaks}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")}"
VERSION="${VERSION#v}"   # strip leading "v" if the tag is e.g. v0.1.0
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"

# Default: ad-hoc sign. Caller can override with --skip-sign or
# --notarize (mutually exclusive).
SIGN_MODE="adhoc"
DO_NOTARIZE=false
for arg in "$@"; do
  case "$arg" in
    --skip-sign)   SIGN_MODE="none" ;;
    --adhoc-sign)  SIGN_MODE="adhoc" ;;     # explicit, same as default
    --notarize)    SIGN_MODE="developer-id"; DO_NOTARIZE=true ;;
    -h|--help)
      sed -n '2,40p' "$0"   # print the header comment as help
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ "$SIGN_MODE" == "developer-id" && -z "$CODESIGN_IDENTITY" ]]; then
  echo "ERROR: --notarize needs CODESIGN_IDENTITY set." >&2
  echo "       See Distribution.md for setting up a Developer ID cert." >&2
  exit 2
fi
if $DO_NOTARIZE && [[ -z "$NOTARYTOOL_PROFILE" ]]; then
  echo "ERROR: NOTARYTOOL_PROFILE not set. Run 'xcrun notarytool store-credentials' first." >&2
  exit 2
fi

# Make sure we're using Xcode's toolchain — CLT alone doesn't ship the
# test libraries and may not include SwiftUI for the universal build.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi

echo "==> Bundle ID:      $BUNDLE_ID"
echo "==> Version:        $VERSION ($BUILD)"
echo "==> Sign mode:      $SIGN_MODE${CODESIGN_IDENTITY:+ ($CODESIGN_IDENTITY)}"
echo "==> Notarize:       $DO_NOTARIZE"

# ----------------------------------------------------------------- build

BUILD_DIR="$REPO_ROOT/build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> swift build (release, universal arm64 + x86_64)…"
swift build \
  -c release \
  --arch arm64 \
  --arch x86_64 \
  --product MacSpoonsTweaks

# SwiftPM places the universal binary under .build/apple/Products/Release.
EXEC_SRC="$REPO_ROOT/.build/apple/Products/Release/MacSpoonsTweaks"
if [[ ! -x "$EXEC_SRC" ]]; then
  # Apple Silicon-only builds end up under .build/release.
  EXEC_SRC="$REPO_ROOT/.build/release/MacSpoonsTweaks"
fi
if [[ ! -x "$EXEC_SRC" ]]; then
  echo "ERROR: built executable not found at expected locations" >&2
  exit 3
fi
echo "==> Built executable: $EXEC_SRC"
echo "    arch(s):" $(lipo -archs "$EXEC_SRC" 2>/dev/null || file "$EXEC_SRC")

# ------------------------------------------------------------ bundle

APP="$BUILD_DIR/MacSpoonsTweaks.app"
echo "==> Constructing ${APP}…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXEC_SRC" "$APP/Contents/MacOS/MacSpoonsTweaks"

# Substitute Info.plist placeholders.
sed -e "s/{{BUNDLE_ID}}/$BUNDLE_ID/g" \
    -e "s/{{VERSION}}/$VERSION/g" \
    -e "s/{{BUILD}}/$BUILD/g" \
    "$REPO_ROOT/tools/Info.plist.template" \
    > "$APP/Contents/Info.plist"

# ------------------------------------------------------------ sign

case "$SIGN_MODE" in
  none)
    echo "==> Skipping codesign (--skip-sign)."
    ;;
  adhoc)
    echo "==> Ad-hoc codesigning (no Apple identity required)…"
    # `--sign -` is ad-hoc: the bundle gets a self-signature that
    # locks its contents but identifies no specific developer.
    # --timestamp is INTENTIONALLY OMITTED — ad-hoc signing can't talk
    # to Apple's timestamp server. The hardened runtime still applies.
    codesign --force \
             --sign - \
             --options runtime \
             --entitlements "$REPO_ROOT/tools/Entitlements.plist" \
             "$APP"

    echo "==> Verifying signature…"
    codesign --verify --deep --strict --verbose=2 "$APP"
    echo "(spctl assess will reject an ad-hoc signed app — that's"
    echo " expected. Users open with right-click → Open the first time.)"
    ;;
  developer-id)
    echo "==> Codesigning with Developer ID + hardened runtime…"
    codesign --force \
             --sign "$CODESIGN_IDENTITY" \
             --options runtime \
             --timestamp \
             --entitlements "$REPO_ROOT/tools/Entitlements.plist" \
             "$APP"

    echo "==> Verifying signature…"
    codesign --verify --deep --strict --verbose=2 "$APP"
    spctl --assess --type execute --verbose=2 "$APP" || {
      echo "(spctl assess will fail until notarization is stapled — expected pre-notarize.)"
    }
    ;;
esac

# ------------------------------------------------------------ notarize

ZIP="$BUILD_DIR/MacSpoonsTweaks-$VERSION.zip"
if $DO_NOTARIZE; then
  echo "==> Zipping for notarization…"
  ditto -c -k --keepParent "$APP" "$ZIP"

  echo "==> Submitting to notarytool (this can take a few minutes)…"
  xcrun notarytool submit "$ZIP" \
        --keychain-profile "$NOTARYTOOL_PROFILE" \
        --wait

  echo "==> Stapling notarization ticket…"
  xcrun stapler staple "$APP"

  # Re-zip after stapling so the distribution archive carries the
  # ticket. (Stapler embeds it into the .app itself.)
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"

  echo "==> Verifying stapled bundle is gatekeeper-approved…"
  spctl --assess --type execute --verbose=2 "$APP"
else
  if [[ "$SIGN_MODE" != "none" ]]; then
    echo "==> Zipping signed (but unnotarized) build…"
    ditto -c -k --keepParent "$APP" "$ZIP"
  fi
fi

echo
echo "Done."
echo "  App:  $APP"
[[ -f "$ZIP" ]] && echo "  Zip:  $ZIP"
