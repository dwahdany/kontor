#!/bin/bash
# Builds a Developer ID signed, notarized and stapled Kontor.app and zips it for distribution.
#
#   KONTOR_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   KONTOR_NOTARY_PROFILE=<notarytool keychain profile> \
#   Scripts/release.sh <version>
#
# Create the profile once with `xcrun notarytool store-credentials <profile>`.
# Without KONTOR_NOTARY_PROFILE the script stops after signing (the zip is then NOT notarized).
# Never launches the app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="${1:?usage: Scripts/release.sh <version>}"
: "${KONTOR_SIGN_IDENTITY:?set KONTOR_SIGN_IDENTITY to a Developer ID Application identity}"
unset KONTOR_FEATURES
KONTOR_VERSION="$VERSION" Scripts/bundle.sh release
APP="$ROOT/dist/Kontor.app"
ZIP="$ROOT/dist/Kontor-$VERSION.zip"
codesign --verify --strict --deep "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
if [[ -z "${KONTOR_NOTARY_PROFILE:-}" ]]; then
    echo "✔ $ZIP (signed, NOT notarized — set KONTOR_NOTARY_PROFILE)"
    exit 0
fi
echo "▸ Notarizing"
xcrun notarytool submit "$ZIP" --keychain-profile "$KONTOR_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
echo "✔ $ZIP (notarized and stapled)"
