#!/bin/zsh
# Usage: scripts/dev.sh   builds + runs Swiftwarden Dev (own bundle id, keychain, settings, data) next to the installed app.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Swiftwarden.xcodeproj -scheme Swiftwarden -configuration Debug -derivedDataPath build/dev -destination 'platform=macOS' build -quiet
osascript -e 'quit app id "com.listjonas.swiftwarden.dev"' 2>/dev/null || true
for i in {1..20}; do pgrep -qx "Swiftwarden Dev" || break; sleep 0.25; done
open "build/dev/Build/Products/Debug/Swiftwarden Dev.app"
