#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

# Records golden vectors by running the probes against a baseline build out of tree.
# usage: scripts/differential/generate.sh [baseline-ref] [areas...]   (default: 2026.10.7, all but observation)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE="$ROOT/scripts/differential"
BASELINE=${1:-2026.10.7}
shift || true
AREAS=("$@")
[ ${#AREAS[@]} -gt 0 ] || AREAS=(audio video helper grid)
WORK="$ROOT/build/differential"
SHA=$(git -C "$ROOT" rev-parse --verify "$BASELINE^{commit}")
TREE="$WORK/tree-$SHA"
DEST=${DEST:-"$ROOT/GlimmerTests/Fixtures/CleanRoomVectors"}
mkdir -p "$WORK" "$DEST"

clang -O1 -I/opt/homebrew/include -L/opt/homebrew/lib -lopus "$HERE/opus-tones.c" -o "$WORK/opus-tones"
python3 "$HERE/make-corpus.py" "$WORK/corpus" "$WORK/opus-tones"

[ -d "$TREE" ] || git -C "$ROOT" worktree add --detach "$TREE" "$SHA"
git -C "$TREE" checkout -q --force "$SHA"
# Replaces one test file of the baseline's own target, so its project needs no edits.
target="$TREE/GlimmerTests/OpusDecoderTests.swift"
{
	cat "$ROOT/GlimmerTests/CleanRoomProbe.swift" "$HERE/CleanRoomOracle.swift"
	for area in "${AREAS[@]}"; do cat "$ROOT/GlimmerTests/CleanRoomProbe+$(tr '[:lower:]' '[:upper:]' <<<"${area:0:1}")${area:1}.swift"; done
	if [[ " ${AREAS[*]} " == *" grid "* ]]; then
		if [ -d "$TREE/GlimmerEngine" ]; then cat "$ROOT/GlimmerTests/CleanRoomGridHost.swift"
		else cat "$HERE/legacy/CleanRoomGridHost.swift"; fi
	fi
	printf 'let cleanRoomOracleAreas = [%s]\n' "$(printf 'CleanRoomProbe.%s, ' "${AREAS[@]}")"
} > "$target"

# A scratch home keeps the baseline's test host away from the real preferences and pairing data.
mkdir -p "$WORK/home" "$WORK/out"
rm -f "$WORK"/out/*.json
(cd "$TREE" && scripts/generate-build-info.sh >/dev/null &&
	TEST_RUNNER_CLEANROOM_CORPUS="$WORK/corpus" TEST_RUNNER_CLEANROOM_OUT="$WORK/out" \
	TEST_RUNNER_CFFIXED_USER_HOME="$WORK/home" \
	xcodebuild test -project Glimmer.xcodeproj -scheme Glimmer -configuration Debug \
		-xcconfig Glimmer/StreamLib.xcconfig CODE_SIGNING_ALLOWED=NO -derivedDataPath "$WORK/derived-$SHA" \
		-destination 'platform=macOS' -only-testing:GlimmerTests/CleanRoomOracle -quiet)
git -C "$TREE" checkout -q --force "$SHA"

for area in "${AREAS[@]}"; do
	python3 "$HERE/merge.py" "$WORK/corpus/$area.json" "$WORK/out/$area.json" "$BASELINE ($SHA)" "$DEST/$area.json"
done
