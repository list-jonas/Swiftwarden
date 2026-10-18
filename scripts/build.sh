#!/bin/zsh
# Usage: scripts/build.sh [Release|Debug]   Release -> dist/Swiftwarden.app, Debug -> dist/Swiftwarden Dev.app
# SIGN_IDENTITY="Developer ID Application: ..." gives a stable signature (keeps Accessibility + Keychain access across builds).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Release}"
NAME=$([[ "$CONFIG" == Debug ]] && echo "Swiftwarden Dev" || echo "Swiftwarden")
DERIVED="${DERIVED_DATA:-build}"
xcodegen generate --quiet
xcodebuild -project Swiftwarden.xcodeproj -scheme Swiftwarden -configuration "$CONFIG" -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build -quiet
APP="dist/$NAME.app"
mkdir -p dist
rm -rf "$APP"
ditto "$DERIVED/Build/Products/$CONFIG/$NAME.app" "$APP"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  for b in "$APP"/Contents/Resources/*.bundle(N); do codesign --force --options runtime --sign "$SIGN_IDENTITY" "$b"; done
  codesign --force --options runtime --entitlements App/Swiftwarden.entitlements --sign "$SIGN_IDENTITY" "$APP"
fi
du -sh "$APP"
