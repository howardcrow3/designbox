#!/usr/bin/env bash
# CI only: import the Mac App Store signing certificates and provisioning profile.
#
# Inputs (env):
#   APPLE_DIST_CERTIFICATE / APPLE_DIST_CERTIFICATE_PASSWORD            base64 .p12 of the "Apple Distribution"
#                                                                        certificate and its private key
#   APPLE_INSTALLER_CERTIFICATE / APPLE_INSTALLER_CERTIFICATE_PASSWORD  base64 .p12 of the "Mac Installer
#                                                                        Distribution" certificate and key
#   APPLE_PROVISIONING_PROFILE                                          base64 of the .provisionprofile
#   KEYCHAIN_PASSWORD (optional; random if unset), RUNNER_TEMP (or TMPDIR)
# Outputs (appended to $GITHUB_ENV in Actions, otherwise printed): MACOS_APP_IDENTITY (SHA-1),
# MACOS_INSTALLER_IDENTITY (certificate name), MACOS_KEYCHAIN, APPSTORE_PROFILE (path).
#
# A missing input is an error: unlike the direct build there is no useful unsigned fallback.
set -euo pipefail
umask 077
# shellcheck source=../env.sh
. "$(dirname "${BASH_SOURCE[0]}")/../env.sh"

missing=""
for name in APPLE_DIST_CERTIFICATE APPLE_DIST_CERTIFICATE_PASSWORD APPLE_INSTALLER_CERTIFICATE \
  APPLE_INSTALLER_CERTIFICATE_PASSWORD APPLE_PROVISIONING_PROFILE; do
  [[ -n "${!name:-}" ]] || missing="$missing $name"
done
if [[ -n "$missing" ]]; then
  echo "error: Mac App Store signing needs these, but they are empty:$missing" >&2
  exit 1
fi

TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
KEYCHAIN="$TMP/designbox-appstore.keychain-db"
KC_PASS="${KEYCHAIN_PASSWORD:-$(openssl rand -hex 24)}"
DIST_P12="$TMP/designbox-dist.p12"
INST_P12="$TMP/designbox-installer.p12"
PROFILE="$TMP/embedded.provisionprofile"

trap 'rm -f "$DIST_P12" "$INST_P12"' EXIT
printf '%s' "$APPLE_DIST_CERTIFICATE" | base64 --decode >"$DIST_P12"
printf '%s' "$APPLE_INSTALLER_CERTIFICATE" | base64 --decode >"$INST_P12"
printf '%s' "$APPLE_PROVISIONING_PROFILE" | base64 --decode >"$PROFILE"

security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security import "$DIST_P12" -P "$APPLE_DIST_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security -t cert -f pkcs12 -k "$KEYCHAIN"
security import "$INST_P12" -P "$APPLE_INSTALLER_CERTIFICATE_PASSWORD" -T /usr/bin/productbuild -T /usr/bin/pkgbuild -T /usr/bin/security -t cert -f pkcs12 -k "$KEYCHAIN"
rm -f "$DIST_P12" "$INST_P12"
security set-key-partition-list -S apple-tool:,apple:,codesign:,productbuild: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

# Older certificates carry the "3rd Party Mac Developer" names; newer ones "Apple Distribution" and
# "Mac Installer Distribution". Accept both.
APP_ID="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/Apple Distribution|3rd Party Mac Developer Application/ { print $2; exit }')"
# Installer certificates are not code-signing identities: list all valid ones and pick by name.
INSTALLER_ID="$(security find-identity -v "$KEYCHAIN" | sed -n 's/.*"\(\(Mac Installer Distribution\|3rd Party Mac Developer Installer\)[^"]*\)".*/\1/p' | head -n 1)"
if [[ -z "$APP_ID" ]] || [[ -z "$INSTALLER_ID" ]]; then
  security find-identity -v "$KEYCHAIN" >&2
  [[ -n "$APP_ID" ]] || echo "error: no 'Apple Distribution' identity in APPLE_DIST_CERTIFICATE" >&2
  [[ -n "$INSTALLER_ID" ]] || echo "error: no 'Mac Installer Distribution' identity in APPLE_INSTALLER_CERTIFICATE" >&2
  exit 1
fi
echo "Imported app identity $APP_ID and installer identity $INSTALLER_ID"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "MACOS_APP_IDENTITY=$APP_ID"
    echo "MACOS_INSTALLER_IDENTITY=$INSTALLER_ID"
    echo "MACOS_KEYCHAIN=$KEYCHAIN"
    echo "APPSTORE_PROFILE=$PROFILE"
  } >>"$GITHUB_ENV"
else
  printf 'MACOS_APP_IDENTITY=%s\nMACOS_INSTALLER_IDENTITY=%s\nMACOS_KEYCHAIN=%s\nAPPSTORE_PROFILE=%s\n' "$APP_ID" "$INSTALLER_ID" "$KEYCHAIN" "$PROFILE"
fi
