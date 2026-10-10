#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

#
# signing-creds.sh - sole reader/writer of the Glimmer signing credentials file.
#
# The release pipeline (make codesign-setup / setup-notary / dist / dev) must be
# non-interactive from ANY session - SSH, cron, a CI runner - which rules out
# both 1Password (`op read` wants an interactive/biometric signin) and the login
# keychain (locked outside GUI sessions; and signing flows that touch the login
# keychain are the known re-prompt trap). So every signing secret lives in ONE
# plain KEY=value file OUTSIDE the repo, protected the same way ~/.ssh keys are:
# owned by the caller, mode 0600/0400. This script refuses anything looser, and
# every Makefile consumer goes through it so the policy has a single home.
#
# Default path: ~/.config/developer-id/signing.env
# Override:     GLIMMER_SIGNING_CREDS env var (the Makefile exports it from its
#               SIGNING_CREDS variable, so `make dist SIGNING_CREDS=...` works).
#
# Subcommands:
#   path                  Print the resolved credentials-file path.
#   check                 Validate existence + ownership + permissions.
#   get KEY [--optional]  Print KEY's value. A missing key is an error unless
#                         --optional (then prints nothing, exits 0).
#   set KEY VALUE         Create or update KEY (creates the file 0600 if absent,
#                         never loosens an existing one). Atomic rewrite.
#   init                  Write a commented template (refuses to overwrite).
#
# File format: one KEY=VALUE per line; the value is everything after the FIRST
# '=' - no quoting, no expansion, quotes would become part of the value. Lines
# starting with '#' are comments. The file is parsed, never sourced, so values
# cannot execute anything.
#
# Keys the Makefile consumes (none are read anywhere else):
#   SIGN_KEYCHAIN_PASSWORD  password of the dedicated release-signing keychain
#                           (auto-generated + stored by `make codesign-setup`)
#   P12_PATH                absolute path to the Developer ID .p12 export
#   P12_PASSWORD            passphrase of that .p12
#   NOTARY_KEY_PATH         absolute path to the App Store Connect API key (.p8)
#   NOTARY_KEY_ID           that key's ID
#   NOTARY_ISSUER_ID        the team's issuer ID

set -euo pipefail

CREDS="${GLIMMER_SIGNING_CREDS:-$HOME/.config/developer-id/signing.env}"

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
    [ -f "$CREDS" ] || die "credentials file not found: $CREDS
  one-time setup:  make creds-init   (writes a template; fill in the values)
  or point GLIMMER_SIGNING_CREDS / make SIGNING_CREDS at an existing file"
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

cmd_set() {
    local key="${1:-}" value="${2:-}"
    require_key "$key"
    [ -n "$value" ] || die "refusing to store an empty value for '$key'"
    umask 077
    mkdir -p "$(dirname "$CREDS")"
    # Never write through a file with loose permissions - fix it first.
    [ ! -f "$CREDS" ] || check_perms
    # Atomic rewrite (filter the old line, append the new) instead of sed -i:
    # values are base64/passwords full of sed-special characters.
    local tmp
    tmp="$(mktemp "$CREDS.XXXXXX")"
    if [ -f "$CREDS" ]; then
        grep -v "^${key}=" "$CREDS" > "$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$CREDS"
}

# Provision missing keys from 1Password - `make dist` "goes and gets what it
# needs". OP_SOURCE in the creds file holds an op://
# item REFERENCE (a pointer - safe in a 0600 file, useless to an attacker
# without the 1Password account); the fixed field map below matches the
# owner's item layout and is documented in the template. Resolution happens
# through `op read`, which raises 1Password's own biometric/approval prompt -
# so this works in GUI sessions and degrades to the manual-fill message
# anywhere op can't authorize. Resolved VALUES land in this file (mode 0600,
# the same trust model as ~/.ssh) so every later run is fully non-interactive.
# Only fills keys that are currently empty; never overwrites.
cmd_fill_from_op() {
    check_perms
    command -v op >/dev/null 2>&1 || die "1Password CLI (op) not installed"
    local source
    source="$(sed -n 's/^OP_SOURCE=//p' "$CREDS" | tail -n 1)"
    [ -n "$source" ] || die "OP_SOURCE not set in $CREDS (e.g. op://<vault>/<item>)"
    local pair key field val dest filled=""
    for pair in \
        "P12_PASSWORD:developer-id-p12-pass" \
        "NOTARY_KEY_ID:notary-key-id" \
        "NOTARY_ISSUER_ID:notary-issuer-id"; do
        key="${pair%%:*}"; field="${pair##*:}"
        # Skip keys that already have a value - fill, never overwrite.
        [ -z "$(sed -n "s/^${key}=//p" "$CREDS" | tail -n 1)" ] || continue
        if val="$(op read "${source}/${field}" 2>/dev/null)" && [ -n "$val" ]; then
            cmd_set "$key" "$val"
            filled="$filled $key"
        fi
    done
    # File fields land beside this file, never in ~/Downloads. `op read --out-file`,
    # not $(...), which corrupts binary. Clear the *_PATH key to re-pull one.
    for pair in "P12_PATH:developer-id-p12:developer-id.p12" "NOTARY_KEY_PATH:notary-key:notary-key.p8"; do
        key="${pair%%:*}"; field="${pair#*:}"; field="${field%%:*}"
        dest="$(dirname "$CREDS")/${pair##*:}"
        [ -z "$(sed -n "s/^${key}=//p" "$CREDS" | tail -n 1)" ] || continue
        if op read --out-file "$dest" "${source}/${field}" >/dev/null 2>&1 && [ -s "$dest" ]; then
            chmod 600 "$dest"
            cmd_set "$key" "$dest"
            filled="$filled $key"
        else
            rm -f "$dest"
        fi
    done
    [ -n "$filled" ] && echo "signing-creds: filled from 1Password:$filled" \
        || echo "signing-creds: nothing fetched (op authorization declined/timed out, or fields absent)" >&2
}

# Consolidated first-run validation: report EVERY unset key among the args in
# one message (the per-key `get` errors made the owner discover gaps one
# painful invocation at a time). Exit 1 if any are missing.
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

cmd_init() {
    [ ! -f "$CREDS" ] || die "$CREDS already exists - refusing to overwrite"
    umask 077
    mkdir -p "$(dirname "$CREDS")"
    cat > "$CREDS" <<'EOF'
# Developer ID signing credentials - keep mode 0600, OUTSIDE any repo.
# Read/written ONLY by scripts/signing-creds.sh (see its header for the rules).
# One KEY=VALUE per line; the value is everything after the first '=' (no
# quotes - they would become part of the value).

# Absolute path to the Developer ID Application cert+key exported as .p12
# (Keychain Access → My Certificates → export, or your password manager).
P12_PATH=
# Passphrase chosen at .p12 export time.
P12_PASSWORD=
# App Store Connect team API key for notarytool (Users and Access → Integrations
# → Team Keys, Developer access). Re-run `make setup-notary` after replacing it.
NOTARY_KEY_PATH=
NOTARY_KEY_ID=
NOTARY_ISSUER_ID=

# Optional: 1Password item REFERENCE for auto-fill (a pointer, not a secret).
# With this set, `make dist` fetches any EMPTY keys above via `op read`
# (1Password will ask for approval). Expected item fields:
#   developer-id-p12-pass → P12_PASSWORD, notary-key-id → NOTARY_KEY_ID,
#   notary-issuer-id → NOTARY_ISSUER_ID, and FILE fields developer-id-p12 and
#   notary-key, saved beside this file as P12_PATH and NOTARY_KEY_PATH.
#OP_SOURCE=op://<vault>/<item>     e.g. op://private/apple-developer-creds

# Filled in automatically by `make codesign-setup`:
#SIGN_KEYCHAIN_PASSWORD=
EOF
    chmod 600 "$CREDS"
    echo "wrote template: $CREDS  (fill in the values, keep mode 0600)"
}

case "${1:-}" in
    (path)  cmd_path ;;
    (check) cmd_check ;;
    (get)   shift; cmd_get "$@" ;;
    (set)   shift; cmd_set "$@" ;;
    (missing) shift; cmd_missing "$@" ;;
    (fill-from-op) cmd_fill_from_op ;;
    (init)  cmd_init ;;
    (*) die "usage: signing-creds.sh path|check|get KEY [--optional]|set KEY VALUE|missing KEY...|fill-from-op|init" ;;
esac
