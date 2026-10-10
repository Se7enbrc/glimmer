#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

# Keep scanner findings out of hook output, including failure diagnostics.
set +x
set -euo pipefail

case "${1:-verified}" in
    verified) FILTER=(--results verified); LABEL="a verified credential" ;;
    private-keys) FILTER=(--include-detectors PrivateKey --no-verification --results unverified); LABEL="a private key" ;;
    *) echo "ERROR: unknown secret scan mode." >&2; exit 1 ;;
esac
unset PRE_COMMIT HUSKY HUSKY_GIT_PARAMS TRUFFLEHOG_PRE_COMMIT
COMMON=(--fail --fail-on-scan-errors --no-update --no-ignore-tag)
WORK=""
trap '[ -z "$WORK" ] || rm -rf "$WORK"' EXIT

scan() {
    local status=0
    trufflehog "$@" "${FILTER[@]}" "${COMMON[@]}" >/dev/null 2>&1 || status=$?
    case "$status" in
        0) return 0 ;;
        183) echo "ERROR: $LABEL is staged or committed. Remove it; contents are withheld." >&2 ;;
        *) echo "ERROR: the secret scan failed (exit $status). Check the TruffleHog installation." >&2 ;;
    esac
    return 1
}

if [ "${GLIMMER_SECRET_SCAN_ALL_FILES:-0}" = 1 ]; then
    WORK="$(mktemp -d)"
    mkdir "$WORK/tree"
    git checkout-index --all --prefix="$WORK/tree/" >/dev/null 2>&1 || {
        echo "ERROR: couldn't prepare tracked files for the secret scan." >&2; exit 1;
    }
    # Scan tracked bytes only; symlinks cannot redirect the scanner outside this copy.
    find "$WORK/tree" -type l -delete
    scan filesystem "$WORK/tree"
fi

FROM="${PRE_COMMIT_FROM_REF:-}"
TO="${PRE_COMMIT_TO_REF:-}"
if [ -n "$FROM$TO" ]; then
    [[ "$FROM" =~ ^[0-9a-f]{40}$ && "$TO" =~ ^[0-9a-f]{40}$ ]] || {
        echo "ERROR: secret scan range requires two full commit SHAs." >&2; exit 1;
    }
    git rev-parse --verify "$FROM^{commit}" >/dev/null 2>&1 &&
        git rev-parse --verify "$TO^{commit}" >/dev/null 2>&1 || {
        echo "ERROR: secret scan range isn't available. Fetch both commits before scanning." >&2; exit 1;
    }
elif [ "${GLIMMER_SECRET_SCAN_ALL_FILES:-0}" = 1 ]; then
    exit 0
else
    FROM=HEAD
    TO=HEAD
fi

scan git "file://$PWD" --since-commit "$FROM" --branch "$TO" \
    --skip-additional-refs --trust-local-git-config
