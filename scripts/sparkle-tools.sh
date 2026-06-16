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

SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.3}"
CACHE="${GLIMMER_SPARKLE_CACHE:-$HOME/.cache/glimmer/sparkle}/$SPARKLE_VERSION"
BIN="$CACHE/bin"

if [ ! -x "$BIN/sign_update" ]; then
	mkdir -p "$CACHE"
	url="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
	echo "▶ fetching Sparkle ${SPARKLE_VERSION} CLI tools..." >&2
	curl -fsSL "$url" -o "$CACHE/sparkle.tar.xz"
	tar -xJf "$CACHE/sparkle.tar.xz" -C "$CACHE"
	rm -f "$CACHE/sparkle.tar.xz"
fi

[ -x "$BIN/sign_update" ] || { echo "ERR: sign_update not found under $BIN after extract" >&2; exit 1; }
echo "$BIN"
