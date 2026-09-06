#!/bin/zsh
# Build, Developer ID-sign, notarize, staple, and install Captions.app.
# Requires: a "Developer ID Application" identity in the login keychain, and
# the App Store Connect API key used for notarization (see KEY_* below).
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_ID="${ASC_KEY_ID:-7NTH26CMV4}"
KEY_ISSUER="${ASC_KEY_ISSUER:-69a6de72-a984-47e3-e053-5b8c7c11a4d1}"
KEY_FILE="${ASC_KEY_FILE:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"
IDENTITY="${DEVID_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[[ -n "$IDENTITY" ]] || { echo "no Developer ID Application identity in keychain" >&2; exit 1; }

OUT=build-release
rm -rf "$OUT"
xcodebuild -project Captions.xcodeproj -scheme Captions -configuration Release \
  -derivedDataPath "$OUT" -allowProvisioningUpdates \
  -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$KEY_ISSUER" -authenticationKeyPath "$KEY_FILE" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM=7PZN69YDL4 \
  PROVISIONING_PROFILE_SPECIFIER="" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  build | tail -3

APP="$OUT/Build/Products/Release/Captions.app"
codesign -vv --deep --strict "$APP"

ZIP="$OUT/Captions.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --key "$KEY_FILE" --key-id "$KEY_ID" --issuer "$KEY_ISSUER" --wait
xcrun stapler staple "$APP"
spctl -a -vv --type execute "$APP"

rm -rf /Applications/Captions.app
ditto "$APP" /Applications/Captions.app
echo "installed /Applications/Captions.app"
