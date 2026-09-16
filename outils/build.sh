#!/bin/bash
# Builds Sonde into a standalone .app bundle using swiftc.
# No SPM, no Xcode project, no external dependencies — Apple frameworks only.
set -euo pipefail

cd "$(dirname "$0")/.."

# Minimum macOS, pinned. Without -target, swiftc stamps the binary with the
# installed SDK's version: the same source produced macOS 27 here and 26.6 on
# CI, and the README's claim went stale with every Xcode update.
DEPLOY="$(uname -m)-apple-macos26.0"

APP="Sonde"
BUNDLE="build/$APP.app"
MACOS_DIR="$BUNDLE/Contents/MacOS"
RES_DIR="$BUNDLE/Contents/Resources"

rm -rf "$BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# Build the app icon from logo.png (multi-resolution .icns) if present.
if [ -f logo.png ]; then
    echo "› Building app icon…"
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size logo.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        d=$((size * 2))
        sips -z $d $d logo.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns"
    rm -rf "$ICONSET"
fi

echo "› Compiling…"
if ! xcrun swiftc \
    -target "$DEPLOY" \
    -parse-as-library \
    -O \
    -swift-version 5 \
    -framework SwiftUI -framework AppKit -framework Network -framework MediaPlayer \
    -o "$MACOS_DIR/$APP" \
    Sources/*.swift 2> build-errors.log; then
    echo "--- swiftc failed, its output follows ---"
    cat build-errors.log
    exit 1
fi
cat build-errors.log

cp Info.plist "$BUNDLE/Contents/Info.plist"

# les deux localisations, sinon macOS n'en voit qu'une (charte §6). Tout le
# dossier, pas seulement Localizable.strings : InfoPlist.strings traduit ce que
# le système affiche lui-même — l'alerte « Réseau local », le nom sous l'icône —
# et une copie nommément limitée l'aurait laissé au sol.
for L in en fr; do
    mkdir -p "$RES_DIR/$L.lproj"
    cp Resources/$L.lproj/*.strings "$RES_DIR/$L.lproj/" 2>/dev/null || true
done

# Sign with a STABLE identity so macOS keeps the "Local Network" permission across
# rebuilds. Ad-hoc signatures change every build, which resets that grant and makes
# the app unable to discover the amp until re-approved. Prefer a real dev identity.
# No signing identity is normal (CI, fresh machine): grep exits 1 and would
# kill the script under `set -e`.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)".*/\1/' || true)
if [ -n "$IDENTITY" ]; then
    echo "› Signing with: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$BUNDLE" >/dev/null 2>&1 || true
else
    echo "› Ad-hoc signing (no stable identity found; Local Network may need re-approval each build)…"
    codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true
fi

# Install to a STABLE location. Running straight from build/ (deleted and recreated
# every build) makes macOS treat the app as new each time and revokes its Local
# Network permission, so it can't reach the amp. /Applications + stable signature
# keeps the grant across rebuilds.
# CI has nowhere to install to, and nothing to grant permissions to.
if [ -n "${CI:-}" ]; then echo "> CI: skipping install"; exit 0; fi
DEST="/Applications/${APP}.app"
echo "> Installing to ${DEST}"
rm -rf "${DEST}"
cp -R "${BUNDLE}" "${DEST}"
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true
if [ -n "${IDENTITY}" ]; then
    codesign --force --deep --sign "${IDENTITY}" "${DEST}" >/dev/null 2>&1 || true
fi

echo "Built and installed ${DEST}"
echo "  Launch it from /Applications (or: open \"${DEST}\")."
echo "  On first launch, allow the local-network / firewall prompt."
