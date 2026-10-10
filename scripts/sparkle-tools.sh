#!/bin/bash
#
# sparkle-tools.sh - ensure Sparkle's CLI tools are available locally and print
# the directory that holds them. Pinned, cached under ~/.cache so the download
# happens once; prompt-free, network only on first use.
#
# The tools (sign_update / generate_appcast / generate_keys / BinaryDelta) ship in
# Sparkle's binary release tarball. The publish pipeline (scripts/publish-release.sh)
# uses sign_update; generate_keys is used once for the EdDSA keypair.
#
# Usage:  TOOLS="$(scripts/sparkle-tools.sh)"   # $TOOLS/sign_update ...
# Pin a different version with SPARKLE_VERSION=... ; relocate the cache with
# GLIMMER_SPARKLE_CACHE=... .
set -euo pipefail

SPARKLE_VERSION="${SPARKLE_VERSION:-2.10.0}"
if [ "$SPARKLE_VERSION" = "2.10.0" ]; then
	SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
else
	SHA256="${SPARKLE_SHA256:?set SPARKLE_SHA256 to the trusted release archive digest when changing Sparkle versions}"
fi
CACHE="${GLIMMER_SPARKLE_CACHE:-$HOME/.cache/glimmer/sparkle}/$SPARKLE_VERSION"
BIN="$CACHE/bin"
STAMP="$CACHE/.verified-sha256"

if [ ! -x "$BIN/sign_update" ] || [ ! -f "$STAMP" ] || [ "$(cat "$STAMP")" != "$SHA256" ]; then
	mkdir -p "$CACHE"
	WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
	url="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
	echo "▶ fetching Sparkle ${SPARKLE_VERSION} CLI tools..." >&2
	curl -fsSL "$url" -o "$WORK/sparkle.tar.xz"
	ACTUAL="$(shasum -a 256 "$WORK/sparkle.tar.xz" | cut -d' ' -f1)"
	[ "$ACTUAL" = "$SHA256" ] || { echo "ERR: Sparkle archive checksum mismatch; refusing to extract tools" >&2; exit 1; }
	tar -xJf "$WORK/sparkle.tar.xz" -C "$CACHE"
	[ -x "$BIN/sign_update" ] || { echo "ERR: verified archive has no sign_update" >&2; exit 1; }
	printf '%s\n' "$SHA256" >"$STAMP"
fi

[ -x "$BIN/sign_update" ] || { echo "ERR: sign_update not found under $BIN after extract" >&2; exit 1; }
echo "$BIN"
