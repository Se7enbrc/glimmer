#!/bin/bash
#
# Sign inside-out, preserving Sparkle's own entitlements. Never sign --deep.
# Args: app, Developer ID identity, optional keychain, app entitlements.
# Profile inputs are explicit GLIMMER_*PROVISIONING_PROFILE environment values.
set -euo pipefail

APP="${1:?usage: sign-bundle.sh <app> <identity> [keychain] <app-entitlements>}"
ID="${2:?Developer ID identity required}"
KC="${3:-}"
ENT="${4:?app entitlements file required}"
HELPER_ENT="LoginHelper/LoginHelper.entitlements"

if [ "$ID" = "-" ]; then
    echo "ERR: restricted capabilities require Developer ID signing" >&2
    exit 1
fi
KCF=(--timestamp); [ -n "$KC" ] && KCF+=(--keychain "$KC")
DAEMON="$APP/Contents/Library/LaunchServices/Glimmer Network Helper.app"
PROFILE="${GLIMMER_PROVISIONING_PROFILE:?set the app Developer ID profile path}"
DAEMON_PROFILE="${GLIMMER_HELPER_PROVISIONING_PROFILE:?set the helper Developer ID profile path}"
RESOLVED=$(mktemp -d "${TMPDIR:-/tmp}/glimmer-sign.XXXXXX")
trap 'rm -rf "$RESOLVED"' EXIT
python3 scripts/provisioning.py --profile "$PROFILE" --app "$APP" \
    --entitlements "$ENT" --output-entitlements "$RESOLVED/app.entitlements"
python3 scripts/provisioning.py --profile "$DAEMON_PROFILE" --app "$DAEMON" \
    --entitlements helper/Helper.entitlements --output-entitlements "$RESOLVED/helper.entitlements"

# Re-sign preserving the target's OWN entitlements + identifier (for Sparkle's
# nested code). Hardened runtime is set explicitly.
sign_pres() { codesign --force --options runtime "${KCF[@]}" --sign "$ID" \
    --preserve-metadata=entitlements,identifier "$1"; }
# Sign with no entitlements (framework bundle / bare binary).
sign_plain() { codesign --force --options runtime "${KCF[@]}" --sign "$ID" "$1"; }

FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
	echo "Signing Sparkle.framework components inside-out (own entitlements preserved)"
	V="$FW/Versions/B"
	if [ -d "$V/Updater.app" ]; then
		for exe in "$V/Updater.app/Contents/MacOS/"*; do [ -f "$exe" ] && sign_pres "$exe"; done
		sign_pres "$V/Updater.app"
	fi
	for xpc in "$V/XPCServices/"*.xpc; do [ -e "$xpc" ] && sign_pres "$xpc"; done
	[ -e "$V/Autoupdate" ] && sign_pres "$V/Autoupdate"
	sign_plain "$FW"
fi

HELPER="$APP/Contents/Library/LoginItems/Glimmer Login Helper.app"
if [ -d "$HELPER" ]; then
	echo "Signing Login Helper with its own entitlements"
	if [ -f "$HELPER_ENT" ]; then
		codesign --force --options runtime "${KCF[@]}" --sign "$ID" --entitlements "$HELPER_ENT" "$HELPER"
	else
		echo "  WARN: $HELPER_ENT not found - preserving the helper's existing entitlements" >&2
		sign_pres "$HELPER"
	fi
fi

# Loose dylibs in Frameworks (e.g. the Address Sanitizer runtime an ASan build
# copies in) are nested code too and must carry our seal before the app does.
for dylib in "$APP/Contents/Frameworks/"*.dylib; do
	[ -f "$dylib" ] && sign_plain "$dylib"
done
echo "Signing the AWDL network helper with its own profile and entitlements"
codesign --force --options runtime "${KCF[@]}" --sign "$ID" \
    --entitlements "$RESOLVED/helper.entitlements" "$DAEMON"

echo "Signing the app bundle (Glimmer entitlements, no --deep)"
codesign --force --options runtime "${KCF[@]}" --sign "$ID" --entitlements "$RESOLVED/app.entitlements" "$APP"

echo "Verifying the whole bundle (deep + strict)"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3
