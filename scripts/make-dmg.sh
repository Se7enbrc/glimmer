#!/bin/bash
#
# make-dmg.sh - build the distributable Glimmer DMG, styled the way a normal Mac
# app installer looks: a background image with an arrow from Glimmer.app to the
# /Applications alias, fixed window bounds, 128px icons, no toolbar or sidebar,
# and the resulting .DS_Store baked into the image.
#
# hdiutil + a Finder AppleScript, the way create-dmg does it, but with no
# Homebrew dependency: the only tools used ship with macOS. If Finder scripting
# is unavailable (no Automation permission, or a session with no window server)
# the styling is SKIPPED with a warning and a plain, perfectly installable DMG
# is produced anyway - a release must never fail over cosmetics.
#
# Args: <app-bundle> <output.dmg> <volume-name>
set -euo pipefail

APP="$1"
OUT="$2"
VOLNAME="$3"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BG_1X="$HERE/scripts/dmg/background.png"
BG_2X="$HERE/scripts/dmg/background@2x.png"

# Window geometry. MUST match scripts/generate-dmg-background.swift, which draws
# the arrow to land between these two icon positions.
WIN_W=660
WIN_H=400
WIN_X=240
WIN_Y=140
ICON_SIZE=128
APP_X=165
APPS_X=495
ICON_Y=200

[ -d "$APP" ] || { echo "ERR: app bundle not found at $APP" >&2; exit 1; }

WORK="$(mktemp -d -t glimmer-dmg)"
STAGE="$WORK/stage"
RW="$WORK/rw.dmg"
DEV=""

cleanup() {
	[ -n "$DEV" ] && hdiutil detach "$DEV" -quiet -force >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

# A leftover mount of the same volume name would make macOS mount ours as
# "<name> 1" and the AppleScript would then style the wrong disk.
if [ -d "/Volumes/$VOLNAME" ]; then
	hdiutil detach "/Volumes/$VOLNAME" -quiet -force >/dev/null 2>&1 || true
fi

echo "  ▶ staging bundle + background"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

# HiDPI background: the 1x and 2x PNGs are combined into a single multi-
# representation TIFF, which is how Finder picks the Retina variant. Only the
# PNGs are committed; the TIFF is a build artifact.
STYLED=1
if [ -f "$BG_1X" ] && [ -f "$BG_2X" ]; then
	tiffutil -cathidpicheck "$BG_1X" "$BG_2X" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1 \
		|| cp "$BG_1X" "$STAGE/.background/background.tiff"
else
	echo "  ! no background art at scripts/dmg/ - run scripts/generate-dmg-background.swift" >&2
	STYLED=0
fi

# Size the read/write image with slack so Finder can write .DS_Store into it.
SIZE_KB=$(( $(du -sk "$STAGE" | awk '{print $1}') + 40000 ))

echo "  ▶ creating read/write image (${SIZE_KB}k)"
rm -f "$RW"
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
	-fsargs "-c c=64,a=16,e=16" -format UDRW -size "${SIZE_KB}k" "$RW" >/dev/null

DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | { grep '^/dev/' || true; } | head -1 | awk '{print $1}')"
[ -n "$DEV" ] || { echo "ERR: could not attach the read/write image" >&2; exit 1; }
MOUNT="/Volumes/$VOLNAME"
[ -d "$MOUNT" ] || { echo "ERR: $MOUNT did not appear after attach" >&2; exit 1; }

if [ "$STYLED" = "1" ]; then
	echo "  ▶ setting the Finder window (${WIN_W}x${WIN_H}, ${ICON_SIZE}px icons)"
	# Written to a file rather than inlined so the quoting stays readable, and
	# so a failure here is a warning rather than a broken release.
	cat >"$WORK/style.applescript" <<APPLESCRIPT
on run argv
	set volName to item 1 of argv
	set appName to item 2 of argv
	tell application "Finder"
		tell disk volName
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set the bounds of container window to {$WIN_X, $WIN_Y, $((WIN_X + WIN_W)), $((WIN_Y + WIN_H))}
			set opts to the icon view options of container window
			set arrangement of opts to not arranged
			set icon size of opts to $ICON_SIZE
			set text size of opts to 12
			set label position of opts to bottom
			set shows item info of opts to false
			set shows icon preview of opts to true
			set background picture of opts to file ".background:background.tiff"
			set position of item appName of container window to {$APP_X, $ICON_Y}
			set position of item "Applications" of container window to {$APPS_X, $ICON_Y}
			close
			open
			update without registering applications
			delay 2
			close
		end tell
	end tell
end run
APPLESCRIPT
	if osascript "$WORK/style.applescript" "$VOLNAME" "$(basename "$APP")" >/dev/null 2>"$WORK/osa.err"; then
		echo "  ✓ window styled"
	else
		echo "  ! Finder styling failed - shipping an unstyled DMG. Detail:" >&2
		sed 's/^/    /' "$WORK/osa.err" >&2 || true
		STYLED=0
	fi
fi

# Give Finder a moment to flush .DS_Store, then verify it actually landed.
sync
sleep 1
if [ -f "$MOUNT/.DS_Store" ]; then
	echo "  ✓ .DS_Store baked in ($(wc -c <"$MOUNT/.DS_Store" | tr -d ' ') bytes)"
elif [ "$STYLED" = "1" ]; then
	echo "  ! no .DS_Store on the volume - the window settings may not stick" >&2
fi

chmod -Rf go-w "$MOUNT" >/dev/null 2>&1 || true
sync

# Detach can lose a race with Finder still holding the volume; retry briefly.
for _ in 1 2 3 4 5; do
	if hdiutil detach "$DEV" -quiet >/dev/null 2>&1; then DEV=""; break; fi
	sleep 1
done
if [ -n "$DEV" ]; then
	hdiutil detach "$DEV" -quiet -force >/dev/null 2>&1 || true
	DEV=""
fi

echo "  ▶ compressing"
rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
