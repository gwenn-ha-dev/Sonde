#!/bin/bash
# `make package` : laisse build/Sonde.app prêt pour `make sign` (CHARTE.md §12).
#
# `make build` (outils/build.sh) assemble déjà le bundle dans build/, le signe —
# identité « Apple Development » si le trousseau en a une, ad hoc sinon, jamais
# `--deep` — et en installe une copie dans /Applications, à dessein (permission
# Réseau local). Ce script ne refait rien de tout cela : il vérifie que le bundle
# est là, entier et scellé. Sonde n'a pas d'entitlements : pas de sandbox, et le
# réseau local passe par Info.plist (NSLocalNetworkUsageDescription,
# NSBonjourServices), que la signature Developer ID garde telle quelle.
#
# La signature Developer ID, la notarisation et le .dmg ne sont pas ici : c'est
# le travail de `make sign` et `make dmg`, avec les outils de la charte.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Sonde.app"
[ -d "$APP" ] || { echo "!! $APP introuvable — make build d'abord" >&2; exit 1; }
codesign --verify --strict --verbose=1 "$APP"
echo "→ $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"))"
