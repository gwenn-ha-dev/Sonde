#!/bin/bash
# Packages build/Sonde.app into a polished drag-to-Applications DMG.
# Run ./build.sh first. Output: build/Sonde.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Sonde"
VOL="Sonde"
SRC_APP="build/$APP.app"
OUT_DMG="build/$APP.dmg"

[ -d "$SRC_APP" ] || { echo "!! $SRC_APP introuvable — lance ./build.sh d'abord"; exit 1; }

WORK=$(mktemp -d)
STAGE="$WORK/stage"
TMP_DMG="$WORK/tmp.dmg"
trap 'rm -rf "$WORK"' EXIT

echo "› Fond de fenêtre…"
xcrun swiftc -O -o "$WORK/dmg-background" packaging/dmg-background.swift
mkdir -p "$STAGE/.background"
"$WORK/dmg-background" logo.png "$STAGE/.background/background.png"
# 144 dpi => Finder affiche le @2x net à 600×420 points.
sips -s dpiWidth 144 -s dpiHeight 144 "$STAGE/.background/background.png" >/dev/null

echo "› Contenu…"
cp -R "$SRC_APP" "$STAGE/$APP.app"
ln -s /Applications "$STAGE/Applications"
# Icône du volume = icône de l'app.
cp "$SRC_APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns" 2>/dev/null || true

echo "› Image temporaire…"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -fs HFS+ -format UDRW "$TMP_DMG" >/dev/null

echo "› Mise en page Finder…"
MOUNT_INFO=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG")
DEV=$(echo "$MOUNT_INFO" | awk 'NR==1{print $1}')
MOUNT="/Volumes/$VOL"

if [ -f "$MOUNT/.VolumeIcon.icns" ] && command -v SetFile >/dev/null; then
    SetFile -a C "$MOUNT"
fi

osascript <<EOS
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 568}
        set vo to the icon view options of container window
        set arrangement of vo to not arranged
        set icon size of vo to 96
        set text size of vo to 12
        set background picture of vo to file ".background:background.png"
        set position of item "$APP.app" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOS

sync
hdiutil detach "$DEV" >/dev/null

echo "› Compression…"
rm -f "$OUT_DMG"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT_DMG" >/dev/null

# Signature (identité stable si dispo — n'évite pas Gatekeeper sur un autre Mac,
# mais garde une provenance cohérente avec l'app).
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)".*/\1/')
[ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$OUT_DMG" >/dev/null 2>&1 || true

echo "OK: $OUT_DMG ($(du -h "$OUT_DMG" | cut -f1 | tr -d ' '))"
echo "Sur un autre Mac : xattr -dr com.apple.quarantine /Applications/$APP.app après la copie."
