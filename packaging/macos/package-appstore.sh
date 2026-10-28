#!/usr/bin/env bash
# Build the Mac App Store package:
#
#   $DIST/designbox-<version>-macos-appstore.pkg    sandboxed DesignBox.app in a signed installer package
#
# Usage: packaging/macos/package-appstore.sh [--arch universal|aarch64|x86_64] [--skip-build]
#                                            [--validate] [--upload]
#
# Differences from package.sh (the direct-download build): the app is sandboxed
# (entitlements-appstore.plist.in), signed with an Apple Distribution identity and the store
# provisioning profile, wrapped in a .pkg signed with a Mac Installer Distribution identity, and
# NOT notarized (App Review replaces notarization). The headless CLI is left out.
#
# Env (CI: import-appstore-certs.sh sets the identities, keychain and profile):
#   MACOS_APP_IDENTITY        codesign identity (Apple Distribution)           required
#   MACOS_INSTALLER_IDENTITY  productbuild identity (Mac Installer Distribution) required
#   APPSTORE_PROFILE          path to the .provisionprofile to embed           required
#   APPLE_TEAM_ID             ten-character Team ID                             required
#   MACOS_KEYCHAIN            keychain holding both identities (optional)
#   APP_STORE_BUILD           CFBundleVersion: an integer that rises with every upload of the store
#                             record (default: UTC yymmddHHMM; CI passes the run number)
# For --validate / --upload (altool with an App Store Connect API key):
#   ASC_KEY_ID, ASC_ISSUER_ID; the key file AuthKey_<ASC_KEY_ID>.p8 must be in ~/private_keys
#   (the workflow writes it there from the ASC_API_KEY secret).
set -euo pipefail
# shellcheck source=../env.sh
. "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
HERE="$ROOT/packaging/macos"

ARCH=universal
SKIP_BUILD=0
VALIDATE=0
UPLOAD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --validate) VALIDATE=1; shift ;;
    --upload) UPLOAD=1; VALIDATE=1; shift ;;
    -h | --help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$ARCH" in
  universal) TARGETS=(aarch64-apple-darwin x86_64-apple-darwin) ;;
  aarch64) TARGETS=(aarch64-apple-darwin) ;;
  x86_64) TARGETS=(x86_64-apple-darwin) ;;
  *) echo "unknown --arch $ARCH" >&2; exit 2 ;;
esac

missing=""
for name in MACOS_APP_IDENTITY MACOS_INSTALLER_IDENTITY APPSTORE_PROFILE APPLE_TEAM_ID; do
  [[ -n "${!name:-}" ]] || missing="$missing $name"
done
if [[ -n "$missing" ]]; then
  echo "error: the Mac App Store build needs these, but they are empty:$missing" >&2
  exit 1
fi
if [[ ! -f "$APPSTORE_PROFILE" ]]; then
  echo "error: APPSTORE_PROFILE does not exist: $APPSTORE_PROFILE" >&2
  exit 1
fi
if [[ ! "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "error: APPLE_TEAM_ID must be the ten-character Team ID" >&2
  exit 1
fi

# Keep in sync with LSMinimumSystemVersion in Info.plist.in.
export MACOSX_DEPLOYMENT_TARGET=11.0
SHORT_VERSION="${VERSION%%-*}"
BUILD_NUMBER="${APP_STORE_BUILD:-$(date -u +%y%m%d%H%M)}"
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "error: APP_STORE_BUILD must be an integer, got '$BUILD_NUMBER'" >&2
  exit 1
fi
WORK="$CARGO_TARGET_DIR/macos-appstore"
APP="$WORK/DesignBox.app"
PKG="$DIST/designbox-$VERSION-macos-appstore.pkg"
KC=()
[[ -n "${MACOS_KEYCHAIN:-}" ]] && KC=(--keychain "$MACOS_KEYCHAIN")

echo "==> DesignBox $VERSION (build $BUILD_NUMBER) for the Mac App Store ($ARCH), team $APPLE_TEAM_ID"

# ---- build (the app only; the CLI is not part of the store app) --------------------------------
if [[ "$SKIP_BUILD" = 0 ]]; then
  args=()
  for t in "${TARGETS[@]}"; do args+=(--target "$t"); done
  (cd "$ROOT" && cargo build --release --locked -p designbox "${args[@]}")
fi

rm -rf "$WORK"
mkdir -p "$WORK/bin"
inputs=()
for t in "${TARGETS[@]}"; do inputs+=("$CARGO_TARGET_DIR/$t/release/designbox"); done
lipo -create -output "$WORK/bin/designbox" "${inputs[@]}"
lipo -info "$WORK/bin/designbox"

# ---- icon (same generation as package.sh) -------------------------------------------------------
ICONS="$ROOT/assets/app-icon"
ICONSET="$WORK/DesignBox.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  cp "$ICONS/designbox-$s.png" "$ICONSET/icon_${s}x${s}.png"
  cp "$ICONS/designbox-$((s * 2)).png" "$ICONSET/icon_${s}x${s}@2x.png"
done
iconutil -c icns -o "$WORK/DesignBox.icns" "$ICONSET"

# ---- DesignBox.app ------------------------------------------------------------------------------
echo "==> assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/bin/designbox" "$APP/Contents/MacOS/DesignBox"
cp "$WORK/DesignBox.icns" "$APP/Contents/Resources/DesignBox.icns"
if [[ -n "${CRAFT_FONTS_DIR:-}" ]]; then
  mkdir -p "$APP/Contents/Resources/Licenses"
  copy_font_licences "$APP/Contents/Resources/Licenses"
fi
sed -e "s/@VERSION@/$VERSION/g" -e "s/@SHORT_VERSION@/$SHORT_VERSION/g" \
  -e "s/@BUILD_SHA@/${DESIGNBOX_BUILD_SHA:-unknown}/g" \
  "$HERE/Info.plist.in" >"$APP/Contents/Info.plist"
# The store requires a CFBundleVersion that rises with every upload; the plist template reuses the
# marketing version, which would be rejected on the second upload of one release.
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' >"$APP/Contents/PkgInfo"
cp "$APPSTORE_PROFILE" "$APP/Contents/embedded.provisionprofile"

sed "s/@TEAM_ID@/$APPLE_TEAM_ID/g" "$HERE/entitlements-appstore.plist.in" >"$WORK/entitlements-appstore.plist"
plutil -lint "$WORK/entitlements-appstore.plist"

# ---- sign ---------------------------------------------------------------------------------------
# Inside-out like package.sh: the only nested code is the main executable. Hardened runtime and a
# secure timestamp are not required by the store but cost nothing.
sign() {
  codesign --force --sign "$MACOS_APP_IDENTITY" ${KC[@]+"${KC[@]}"} --timestamp \
    --options runtime --entitlements "$WORK/entitlements-appstore.plist" "$@"
}
sign "$APP/Contents/MacOS/DesignBox"
sign "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"
echo "==> entitlements in the signed app:"
codesign -d --entitlements :- "$APP" 2>/dev/null || true

# ---- installer package --------------------------------------------------------------------------
echo "==> building $PKG"
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$MACOS_INSTALLER_IDENTITY" \
  ${KC[@]+"${KC[@]}"} --timestamp "$PKG"
pkgutil --check-signature "$PKG"

# ---- validate / upload --------------------------------------------------------------------------
altool() {
  if [[ -z "${ASC_KEY_ID:-}" ]] || [[ -z "${ASC_ISSUER_ID:-}" ]]; then
    echo "error: --validate/--upload need ASC_KEY_ID and ASC_ISSUER_ID" >&2
    exit 1
  fi
  xcrun altool "$1" -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
}
if [[ "$VALIDATE" = 1 ]]; then
  echo "==> validating with App Store Connect"
  altool --validate-app
fi
if [[ "$UPLOAD" = 1 ]]; then
  echo "==> uploading to App Store Connect"
  altool --upload-app
else
  echo "==> not uploaded: pass --upload, or add $PKG with Apple's Transporter app"
fi

echo "==> done"
ls -lh "$PKG"
