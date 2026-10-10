#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

# Prove the unsigned Release payload is reproducible (docs/RELEASE.md, "Reproducible
# payload"): build HEAD twice in fresh clones and compare, or compare two bundles.
# Usage: compare-builds.sh [WORKDIR] | compare-builds.sh [--normalize] A.app B.app
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=build/Build/Products/Release/Glimmer.app

# actool stamps the catalog and names Icon Composer renditions after temporary files (their
# digests change with them), so an asset catalog is compared through assetutil without those.
catalog() {
    python3 - "$1" <<'PY'
import json, subprocess, sys
entries = json.loads(subprocess.check_output(["xcrun", "assetutil", "--info", sys.argv[1]]))
for entry in entries:
    entry.pop("Timestamp", None)
    if "_NSAppearanceName" in entry.get("RenditionName", ""):
        entry.pop("RenditionName")
        entry.pop("SHA1Digest", None)
print(json.dumps(entries, indent=1, sort_keys=True))
PY
}

# Mode, path and link target of every entry, then a digest of every regular file.
manifest() {
    (cd "$1" && find . -print0 | sort -z | xargs -0 stat -f '%Sp %N %Y' \
        && find . -type f ! -name Assets.car -print0 | sort -z | xargs -0 shasum -a 256 \
        && find . -name Assets.car | sort | while read -r car; do echo "$car"; catalog "$car"; done)
}

# Drop the seals, profiles, ticket and Mach-O signatures a shipped copy carries. strip then
# relays __LINKEDIT, which removal leaves sized for the old signature.
normalize() {
    find "$1" \( -name _CodeSignature -o -name CodeResources -o -name embedded.provisionprofile \) \
        -prune -exec rm -rf {} +
    find "$1" -type f -print0 | while IFS= read -r -d '' binary; do
        if file -b "$binary" | grep -q '^Mach-O'; then
            codesign --remove-signature "$binary"
            xcrun strip -D -S "$binary"
        fi
    done
}

compare() {
    local report
    if report="$(diff -u <(manifest "$1") <(manifest "$2"))"; then
        echo "identical: $1 and $2 ($(find "$1" -type f | wc -l | tr -d ' ') files)"
    else
        printf 'different: %s and %s\n%s\n' "$1" "$2" "$report" >&2
        return 1
    fi
}

build_twice() {
    local work="${1:-$(mktemp -d "${TMPDIR:-/tmp}/glimmer-repro.XXXXXX")}"
    local rev
    rev="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    git -C "$REPO_ROOT" diff --quiet HEAD || echo "note: uncommitted changes stay out of both clones" >&2
    for n in a b; do
        rm -rf "$work/$n"
        git clone -q --no-checkout "$REPO_ROOT" "$work/$n"
        git -C "$work/$n" checkout -q "$rev"
        make -C "$work/$n" CONFIG=Release app embed-helper
    done
    compare "$work/a/$APP" "$work/b/$APP"
}

case "${1:-}" in
    --normalize)
        copies="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-normalized.XXXXXX")"
        trap 'rm -rf "$copies"' EXIT
        for n in a b; do
            cp -Rp "${2:?usage: --normalize A.app B.app}" "$copies/$n.app"
            shift
            normalize "$copies/$n.app"
        done
        compare "$copies/a.app" "$copies/b.app"
        ;;
    *)
        if [ $# -eq 2 ]; then compare "$1" "$2"; else build_twice "${1:-}"; fi
        ;;
esac
