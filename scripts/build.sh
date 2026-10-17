#!/bin/zsh
# Usage: scripts/build.sh [Debug|Release]
# Set SIGN_IDENTITY="Developer ID Application: ..." for a stable signature (keeps Accessibility permission across builds).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Release}"
xcodegen generate --quiet
xcodebuild -project Swiftwarden.xcodeproj -scheme Swiftwarden -configuration "$CONFIG" -derivedDataPath build \
  -destination 'platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build -quiet
APP="build/Build/Products/$CONFIG/Swiftwarden.app"
mkdir -p dist
rm -rf dist/Swiftwarden.app
ditto "$APP" dist/Swiftwarden.app
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  for b in dist/Swiftwarden.app/Contents/Resources/*.bundle(N); do codesign --force --options runtime --sign "$SIGN_IDENTITY" "$b"; done
  codesign --force --options runtime --entitlements App/Swiftwarden.entitlements --sign "$SIGN_IDENTITY" dist/Swiftwarden.app
fi
du -sh dist/Swiftwarden.app
