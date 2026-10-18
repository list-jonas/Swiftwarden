#!/bin/zsh
# Usage: scripts/install.sh   builds Release, installs /Applications/Swiftwarden.app, enables launch at login, starts it.
# Signs with SIGN_IDENTITY, else the first Developer ID identity found, else ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
fi
export SIGN_IDENTITY
DERIVED_DATA=build/release scripts/build.sh Release
osascript -e 'quit app id "com.listjonas.swiftwarden"' 2>/dev/null || true
for i in {1..20}; do pgrep -qx Swiftwarden || break; sleep 0.25; done
rm -rf /Applications/Swiftwarden.app
ditto dist/Swiftwarden.app /Applications/Swiftwarden.app
open /Applications/Swiftwarden.app
echo "Installed /Applications/Swiftwarden.app (${SIGN_IDENTITY:-ad-hoc})"
