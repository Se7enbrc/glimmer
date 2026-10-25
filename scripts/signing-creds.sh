#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

set -euo pipefail

[[ "${CI:-}:${GITHUB_ACTIONS:-}" = true:true && -n "${RUNNER_TEMP:-}" ]] || {
    echo 'Signing credentials are available only in hosted release jobs.' >&2; exit 1;
}
CREDS="${GLIMMER_SIGNING_CREDS:?CI must provide a temporary credentials file}"
case "$CREDS" in "$RUNNER_TEMP"/*) ;; *) echo 'Credentials must be in RUNNER_TEMP.' >&2; exit 1 ;; esac

die() { echo "signing-creds: $*" >&2; exit 1; }

# Key names are a fixed vocabulary - validate before they reach grep/sed so a
# malformed caller can't smuggle regex metacharacters into the file scan.
require_key() {
    case "${1:-}" in
        ('' | *[!A-Z0-9_]*) die "invalid key name '${1:-}' (A-Z, 0-9, _ only)" ;;
    esac
}

# The whole trust model is "this file is as private as an ssh key" - enforce it
# on every read so a chmod slip can't silently leak the .p12 passphrase.
check_perms() {
    [ -f "$CREDS" ] || die "CI credentials file missing"
    local owner mode
    owner="$(stat -f '%u' "$CREDS")"
    mode="$(stat -f '%Lp' "$CREDS")"
    [ "$owner" = "$(id -u)" ] || die "$CREDS is not owned by you (uid $owner)"
    case "$mode" in
        (600 | 400) ;;
        (*) die "$CREDS has mode $mode - must be 0600 or 0400: chmod 600 '$CREDS'" ;;
    esac
}

cmd_path() { printf '%s\n' "$CREDS"; }

cmd_check() {
    check_perms
    echo "ok: $CREDS"
}

cmd_get() {
    local key="${1:-}" optional="${2:-}"
    require_key "$key"
    check_perms
    local val
    val="$(sed -n "s/^${key}=//p" "$CREDS" | tail -n 1)"
    if [ -z "$val" ]; then
        [ "$optional" = "--optional" ] && return 0
        die "key '$key' not set in $CREDS"
    fi
    printf '%s\n' "$val"
}

cmd_missing() {
    check_perms
    local missing="" key val
    for key in "$@"; do
        require_key "$key"
        val="$(sed -n "s/^${key}=//p" "$CREDS" | tail -n 1)"
        [ -n "$val" ] || missing="$missing $key"
    done
    if [ -n "$missing" ]; then
        echo "signing-creds: not yet filled in ($CREDS):$missing" >&2
        return 1
    fi
}

case "${1:-}" in
    (path)  cmd_path ;;
    (check) cmd_check ;;
    (get)   shift; cmd_get "$@" ;;
    (missing) shift; cmd_missing "$@" ;;
    (*) die "usage: signing-creds.sh path|check|get KEY [--optional]|missing KEY..." ;;
esac
