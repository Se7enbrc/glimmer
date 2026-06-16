#!/bin/bash
#
# embed-dylibs.sh — make a built Glimmer.app self-contained for distribution
#
# The Release build links openssl@3 (libssl + libcrypto) and opus from
# /opt/homebrew/opt/.../lib/*. Those paths don't exist on user machines,
# and even when they do, Hardened Runtime library validation rejects them
# because Homebrew's CI signs with a different Team ID than our adhoc app
# (so loading fails with "non-platform mapping with different Team IDs").
#
# This script:
#   1. Copies the three Homebrew dylibs into Glimmer.app/Contents/Frameworks/
#   2. Rewrites each dylib's install_name (id) to @rpath/<file>
#   3. Rewrites libssl's libcrypto reference to @rpath
#   4. Rewrites the main binary's three references to @rpath
#   5. Re-signs the embedded dylibs with the adhoc identity + runtime option
#   6. Re-signs the app bundle so its hashes match (entitlements preserved)
#
# Run after xcodebuild -configuration Release, before packaging the DMG.
#
# Args:
#   $1 — absolute path to Glimmer.app (Release build product)
#
# Requires `/opt/homebrew/opt/openssl@3` and `/opt/homebrew/opt/opus` to be
# present on the build machine. The CI host needs `brew install openssl@3 opus`
# the same as a development machine.

set -euo pipefail

APP="${1:?usage: embed-dylibs.sh /path/to/Glimmer.app [signing-identity]}"

# Signing identity: arg $2 wins, else $SIGN_IDENTITY env, else adhoc ("-").
# A real "Developer ID Application: …" identity triggers a *secure timestamp*
# (--timestamp) and hardened runtime, both REQUIRED for notarization. Adhoc
# keeps the prior local-dev behaviour (no timestamp server round-trip).
SIGN_IDENTITY="${2:-${SIGN_IDENTITY:--}}"
# Optional 3rd arg: keychain to PIN identity resolution to. The same
# Developer ID cert usually exists in the login keychain too (the original
# import), and codesign resolving by NAME can land on that unauthorized copy
# and prompt per dylib — pinning makes prompts structurally impossible.
SIGN_KEYCHAIN="${3:-}"
KC_FLAG=""
[ -n "$SIGN_KEYCHAIN" ] && [ "$SIGN_IDENTITY" != "-" ] && KC_FLAG="--keychain $SIGN_KEYCHAIN"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  TS_FLAG="--timestamp=none"
  echo "Signing identity: adhoc (local dev — NOT notarizable)"
else
  TS_FLAG="--timestamp"
  echo "Signing identity: $SIGN_IDENTITY (secure timestamp + hardened runtime)"
fi

if [[ ! -d "$APP" ]]; then
  echo "ERR: app bundle not found at $APP" >&2
  exit 1
fi

OPENSSL_PREFIX="$(brew --prefix openssl@3)"
OPUS_PREFIX="$(brew --prefix opus)"

BIN="$APP/Contents/MacOS/Glimmer"
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

echo "Embedding dylibs into $FRAMEWORKS"
cp "$OPENSSL_PREFIX/lib/libssl.3.dylib"     "$FRAMEWORKS/"
cp "$OPENSSL_PREFIX/lib/libcrypto.3.dylib"  "$FRAMEWORKS/"
cp "$OPUS_PREFIX/lib/libopus.0.dylib"       "$FRAMEWORKS/"
chmod u+w "$FRAMEWORKS"/lib*.dylib

echo "Rewriting dylib install names"
install_name_tool -id @rpath/libssl.3.dylib    "$FRAMEWORKS/libssl.3.dylib"
install_name_tool -id @rpath/libcrypto.3.dylib "$FRAMEWORKS/libcrypto.3.dylib"
install_name_tool -id @rpath/libopus.0.dylib   "$FRAMEWORKS/libopus.0.dylib"

# Rewrite EVERY Homebrew-path reference each Mach-O actually carries, as
# reported by otool — never a hardcoded expected path. References are spelled
# inconsistently: the app binary records the `opt` symlink path it linked
# against, but brew's dylibs reference each other via the REAL
# `Cellar/<version>` path. `install_name_tool -change` with a non-matching
# old path is a SILENT no-op — that exact mismatch shipped 2026.6.2 with
# libssl still loading libcrypto from /opt/homebrew/Cellar/..., which fails
# to launch on any Mac without Homebrew (issue #18).
rewrite_brew_refs() {
  local target="$1" ref base
  while IFS= read -r ref; do
    case "$ref" in
      /opt/homebrew/*|/usr/local/*)
        base="$(basename "$ref")"
        if [[ ! -f "$FRAMEWORKS/$base" ]]; then
          echo "ERR: $target references $ref but $base is not embedded" >&2
          echo "     (add it to the copy list above)" >&2
          exit 1
        fi
        install_name_tool -change "$ref" "@rpath/$base" "$target"
        ;;
    esac
  done < <(otool -L "$target" | awk 'NR>1 {print $1}')
}

echo "Rewriting brew references (binary + embedded dylibs)"
rewrite_brew_refs "$BIN"
for lib in "$FRAMEWORKS"/lib*.dylib; do
  rewrite_brew_refs "$lib"
done

# Hard gate: a self-contained bundle has ZERO absolute brew paths left in any
# Mach-O. Failing here catches the next silent no-op at dist time instead of
# on a user's brew-less Mac.
echo "Verifying self-containment"
for macho in "$BIN" "$FRAMEWORKS"/lib*.dylib; do
  if otool -L "$macho" | awk 'NR>1 {print $1}' | grep -qE '^(/opt/homebrew|/usr/local)/'; then
    echo "ERR: $macho still references Homebrew paths:" >&2
    otool -L "$macho" | grep -E '/opt/homebrew|/usr/local' >&2
    exit 1
  fi
done

# Sign inside-out: nested dylibs first, then the bundle. A Developer ID
# signature is destroyed if anything inside it is re-signed afterward, so the
# app MUST be signed last.
echo "Re-signing embedded dylibs"
for lib in "$FRAMEWORKS"/lib*.dylib; do
  codesign --force --sign "$SIGN_IDENTITY" $KC_FLAG --options runtime $TS_FLAG "$lib"
done

echo "Re-signing app (preserving existing entitlements)"
ENTITLEMENTS="$(mktemp -t entitlements).plist"
codesign --display --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null || true
if [[ -s "$ENTITLEMENTS" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" $KC_FLAG --options runtime $TS_FLAG --entitlements "$ENTITLEMENTS" "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" $KC_FLAG --options runtime $TS_FLAG "$APP"
fi
rm -f "$ENTITLEMENTS"

echo "Verifying"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -5
echo
otool -L "$BIN" | grep -E '(libssl|libcrypto|libopus)' || {
  echo "WARN: no dylib references found in linked binary?" >&2
}

echo "Done."
