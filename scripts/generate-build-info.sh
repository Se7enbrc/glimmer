#!/bin/bash
#
# generate-build-info.sh — stamp the git commit SHA + build date into a generated
# Swift constant so every telemetry session/metric is attributable to a build
# (regression tracking).
#
# Writes Glimmer/BuildInfo.generated.swift with `BuildInfo.commit` + `.date`.
# Run from the Makefile's `app` target BEFORE xcodebuild, so the constant is
# fresh for the build it ships in. IDEMPOTENT: only rewrites the file when the
# contents actually change, so a no-op `make app` doesn't dirty the file or force
# Swift to recompile the (unchanged) generated unit.
#
# The SHA is the short (12-char) HEAD with a "-dirty" suffix when the worktree
# has uncommitted changes — so a metric never silently claims a clean build it
# wasn't. Outside a git checkout (a source tarball) it falls back to "unknown".
#
# Secret-free by construction: a commit SHA + an ISO date carry nothing sensitive
# and are exactly the attribution a regression hunt needs.

set -euo pipefail

# Resolve repo root from this script's location so it works regardless of CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$REPO_ROOT/Glimmer/BuildInfo.generated.swift"

commit="unknown"
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    commit="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
    # Flag a dirty worktree so a metric can never claim a clean build it wasn't.
    if ! git -C "$REPO_ROOT" diff --quiet HEAD 2>/dev/null; then
        commit="${commit}-dirty"
    fi
fi

# UTC ISO8601 (date-only is enough for regression buckets; keep it compact).
build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

contents="$(cat <<EOF
//
//  BuildInfo.generated.swift
//
//  GENERATED — do not edit. Written by scripts/generate-build-info.sh on each
//  \`make app\`. Stamps the git commit SHA + build date so every telemetry
//  session/metric is attributable to a build (regression tracking). Secret-free:
//  a commit SHA + an ISO date carry nothing sensitive.
//

enum BuildInfo {
    /// Short git HEAD (12 hex) at build time, "-dirty" when the worktree had
    /// uncommitted changes, or "unknown" outside a git checkout.
    static let commit = "$commit"
    /// UTC ISO8601 build timestamp.
    static let date = "$build_date"
}
EOF
)"

# Only rewrite when the SHA changed — the date alone changing every build would
# needlessly recompile, so we compare on the commit line only.
if [ -f "$OUT" ] && grep -q "static let commit = \"$commit\"" "$OUT"; then
    exit 0
fi

printf '%s\n' "$contents" > "$OUT"
echo "  ✓ BuildInfo.generated.swift → commit=$commit"
