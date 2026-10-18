#!/bin/zsh
# Usage: scripts/dmg.sh [app] [output.dmg]   needs: pip3 install dmgbuild
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/Swiftwarden.app}"
OUT="${2:-dist/Swiftwarden.dmg}"
if [[ ! -f scripts/dmg/background.tiff || scripts/dmg/background.swift -nt scripts/dmg/background.tiff ]]; then
  swift scripts/dmg/background.swift scripts/dmg/background.png 1
  swift scripts/dmg/background.swift scripts/dmg/background@2x.png 2
  tiffutil -cathidpicheck scripts/dmg/background.png scripts/dmg/background@2x.png -out scripts/dmg/background.tiff
  rm -f scripts/dmg/background.png scripts/dmg/background@2x.png
fi
rm -f "$OUT"
python3 -m dmgbuild -s scripts/dmg/settings.py -D app="$APP" "Swiftwarden" "$OUT"
du -h "$OUT"
