#!/bin/zsh
# Usage: scripts/install.sh   builds Release, installs /Applications/Swiftwarden.app, enables launch at login, starts it.
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED_DATA=build/release scripts/build.sh Release
osascript -e 'quit app id "com.listjonas.swiftwarden"' 2>/dev/null || true
for i in {1..20}; do pgrep -qx Swiftwarden || break; sleep 0.25; done
defaults delete com.listjonas.swiftwarden loginItemConfigured 2>/dev/null || true
rm -rf /Applications/Swiftwarden.app
ditto dist/Swiftwarden.app /Applications/Swiftwarden.app
open /Applications/Swiftwarden.app
echo "Installed /Applications/Swiftwarden.app"
