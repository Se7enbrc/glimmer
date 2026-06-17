#!/bin/bash
#
# sign-bundle.sh - inside-out codesign of Glimmer.app. NO `--deep`.
#
# `--deep` is the wrong tool here: it re-signs nested code (Sparkle's framework +
# its Updater.app / Autoupdate / Installer.xpc / Downloader.xpc, and the Login
# Helper) with the MAIN app's `--entitlements`, clobbering each component's own
# entitlements. Verified 2026-06: it stamped Glimmer's device.usb / bluetooth /
# moonlight shared-preference exceptions onto Sparkle's Downloader.xpc - junk for
# a downloader, and exactly what breaks the sandboxed installer XPC at runtime.
# Apple deprecated `--deep` for distribution for the same reason.
#
# Instead we sign deepest-first: each Sparkle component re-signed with OUR
# Developer-ID but PRESERVING its own entitlements/identifier, the Login Helper
# with its own entitlements, then the app last with Glimmer's entitlements. The
# embedded openssl/opus dylibs are added + signed later by embed-dylibs.sh, which
# re-signs only the app's OUTER seal (nested signatures are preserved).
#
# Args:
#   $1  app path (Glimmer.app)
#   $2  signing identity ('-' for adhoc)
#   $3  keychain to pin identity resolution to (optional)
#   $4  the app's entitlements file (Glimmer/Glimmer.entitlements)
set -euo pipefail

APP="${1:?usage: sign-bundle.sh <app> <identity> [keychain] <app-entitlements>}"
ID="${2:?identity required ('-' for adhoc)}"
KC="${3:-}"
ENT="${4:?app entitlements file required}"
HELPER_ENT="LoginHelper/LoginHelper.entitlements"

KCF=""; [ -n "$KC" ] && [ "$ID" != "-" ] && KCF="--keychain $KC"
if [ "$ID" = "-" ]; then TS="--timestamp=none"; else TS="--timestamp"; fi

# Re-sign preserving the target's OWN entitlements + identifier (for Sparkle's
# nested code). Hardened runtime is set explicitly.
sign_pres() { codesign --force --options runtime $TS $KCF --sign "$ID" \
    --preserve-metadata=entitlements,identifier "$1"; }
# Sign with no entitlements (framework bundle / bare binary).
sign_plain() { codesign --force --options runtime $TS $KCF --sign "$ID" "$1"; }

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
		codesign --force --options runtime $TS $KCF --sign "$ID" --entitlements "$HELPER_ENT" "$HELPER"
	else
		echo "  WARN: $HELPER_ENT not found - preserving the helper's existing entitlements" >&2
		sign_pres "$HELPER"
	fi
fi

DAEMON="$APP/Contents/MacOS/io.ugfugl.glimmer.helper"
if [ -f "$DAEMON" ]; then
	echo "Signing the AWDL network helper (root LaunchDaemon, hardened runtime, no entitlements)"
	codesign --force --options runtime $TS $KCF --sign "$ID" --identifier "io.ugfugl.glimmer.helper" "$DAEMON"
fi

echo "Signing the app bundle (Glimmer entitlements, no --deep)"
codesign --force --options runtime $TS $KCF --sign "$ID" --entitlements "$ENT" "$APP"

echo "Verifying the whole bundle (deep + strict)"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3
