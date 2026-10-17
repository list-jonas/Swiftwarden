#!/bin/zsh
# Usage: scripts/build.sh [Debug|Release]
# Set SIGN_IDENTITY="Developer ID Application: ..." for a stable signature (keeps Accessibility permission across builds).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Release}"
xcodegen generate --quiet
xcodebuild -project Swiftwarden.xcodeproj -scheme Swiftwarden -configuration "$CONFIG" -derivedDataPath build \
  CODE_SIGN_IDENTITY="${SIGN_IDENTITY:--}" OTHER_CODE_SIGN_FLAGS="--timestamp=none" build -quiet
APP="build/Build/Products/$CONFIG/Swiftwarden.app"
mkdir -p dist
ditto "$APP" dist/Swiftwarden.app
du -sh dist/Swiftwarden.app
