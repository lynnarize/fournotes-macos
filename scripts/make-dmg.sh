#!/bin/bash
# Builds Four Notes and packages it as a drag-to-Applications disk image:
# the app on the left, an Applications shortcut on the right, and a
# background with an arrow between them.
#
#   ./scripts/make-dmg.sh             build Release, then package
#   ./scripts/make-dmg.sh --no-build  package the Release build already there
#
# Output: build/FourNotes-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Four Notes"
APP="build/dd/Build/Products/Release/FourNotes.app"
WORK="build/dmg"

if [[ "${1:-}" != "--no-build" ]]; then
    echo "→ Building Release…"
    xcodegen generate >/dev/null
    xcodebuild -project FourNotes.xcodeproj -scheme FourNotes -configuration Release \
        -derivedDataPath build/dd build -quiet
fi
[[ -d "$APP" ]] || { echo "No Release build at $APP"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
OUT="build/FourNotes-$VERSION.dmg"
echo "→ Packaging $NAME $VERSION"

# A volume left mounted by an earlier run would make the new one "Four Notes 1".
if [[ -d "/Volumes/$NAME" ]]; then hdiutil detach "/Volumes/$NAME" -quiet -force || true; fi

rm -rf "$WORK"
mkdir -p "$WORK/stage/.background"
ditto "$APP" "$WORK/stage/$NAME.app"
ln -s /Applications "$WORK/stage/Applications"

# Background, at 1x and 2x so it is sharp on Retina.
swift scripts/dmg-background.swift "$WORK/bg.png" 1
swift scripts/dmg-background.swift "$WORK/bg@2x.png" 2
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/stage/.background/background.tiff" 2>/dev/null

# A writable image first, so Finder can save the window layout into it.
hdiutil create -volname "$NAME" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" -quiet
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk '/Apple_HFS/ {print $1}')
sleep 1

# Window size, icon size and positions, and the background. Finder does this;
# the first run asks for permission to control Finder.
if ! osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 520}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "$NAME.app" of container window to {180, 190}
        set position of item "Applications" of container window to {480, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
    echo "! Finder couldn't lay out the window (allow Terminal to control Finder in"
    echo "  System Settings → Privacy & Security → Automation). The image still works."
fi

chmod -Rf go-w "/Volumes/$NAME" 2>/dev/null || true
sync
hdiutil detach "$DEVICE" -quiet || hdiutil detach "$DEVICE" -force -quiet

rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
hdiutil verify "$OUT" -quiet
rm -rf "$WORK"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
