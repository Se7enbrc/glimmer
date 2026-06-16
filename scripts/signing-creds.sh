#!/bin/bash
#
# signing-creds.sh — sole reader/writer of the Glimmer signing credentials file.
#
# The release pipeline (make codesign-setup / setup-notary / dist / dev) must be
# non-interactive from ANY session — SSH, cron, a CI runner — which rules out
# both 1Password (`op read` wants an interactive/biometric signin) and the login
# keychain (locked outside GUI sessions; and signing flows that touch the login
# keychain are the known re-prompt trap). So every signing secret lives in ONE
# plain KEY=value file OUTSIDE the repo, protected the same way ~/.ssh keys are:
# owned by the caller, mode 0600/0400. This script refuses anything looser, and
# every Makefile consumer goes through it so the policy has a single home.
#
# Default path: ~/.config/glimmer/signing.env
# Override:     GLIMMER_SIGNING_CREDS env var (the Makefile exports it from its
#               SIGNING_CREDS variable, so `make dist SIGNING_CREDS=…` works).
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
# '=' — no quoting, no expansion, quotes would become part of the value. Lines
# starting with '#' are comments. The file is parsed, never sourced, so values
# cannot execute anything.
#
# Keys the Makefile consumes (none are read anywhere else):
#   SIGN_KEYCHAIN_PASSWORD  password of the dedicated release-signing keychain
#                           (auto-generated + stored by `make codesign-setup`)
#   DEV_KEYCHAIN_PASSWORD   password of the dedicated dev-signing keychain
#                           (auto-generated + stored by `make dev-sign-setup`)
#   P12_PATH                absolute path to the Developer ID .p12 export
#   P12_PASSWORD            passphrase of that .p12
#   APPLE_ID                Apple ID email for notarytool
#   APPLE_APP_PASSWORD      app-specific password for notarytool
#   APPLE_TEAM_ID           (optional) 10-char team id; derived from the
#                           Developer ID cert name when absent

set -euo pipefail

CREDS="${GLIMMER_SIGNING_CREDS:-$HOME/.config/glimmer/signing.env}"

die() { echo "signing-creds: $*" >&2; exit 1; }

# Key names are a fixed vocabulary — validate before they reach grep/sed so a
# malformed caller can't smuggle regex metacharacters into the file scan.
require_key() {
    case "${1:-}" in
        ('' | *[!A-Z0-9_]*) die "invalid key name '${1:-}' (A-Z, 0-9, _ only)" ;;
    esac
}

# The whole trust model is "this file is as private as an ssh key" — enforce it
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
        (*) die "$CREDS has mode $mode — must be 0600 or 0400: chmod 600 '$CREDS'" ;;
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
    # Never write through a file with loose permissions — fix it first.
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

# Provision missing keys from 1Password — `make dist` "goes and gets what it
# needs". OP_SOURCE in the creds file holds an op://
# item REFERENCE (a pointer — safe in a 0600 file, useless to an attacker
# without the 1Password account); the fixed field map below matches the
# owner's item layout and is documented in the template. Resolution happens
# through `op read`, which raises 1Password's own biometric/approval prompt —
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
    local pair key field val filled=""
    for pair in \
        "APPLE_ID:username" \
        "APPLE_APP_PASSWORD:glimmer-app-pass" \
        "APPLE_TEAM_ID:team-id" \
        "P12_PASSWORD:developer-id-p12-pass"; do
        key="${pair%%:*}"; field="${pair##*:}"
        # Skip keys that already have a value — fill, never overwrite.
        [ -z "$(sed -n "s/^${key}=//p" "$CREDS" | tail -n 1)" ] || continue
        if val="$(op read "${source}/${field}" 2>/dev/null)" && [ -n "$val" ]; then
            cmd_set "$key" "$val"
            filled="$filled $key"
        fi
    done
    # Materialize the Developer ID .p12 itself (a FILE field on the item) so the
    # cert+key come from the vault, not a loose file in ~/Downloads. Binary —
    # use `op read --out-file`, NEVER $(...) (command substitution corrupts
    # binary + drops NULs). Fill only when P12_PATH is unset, mirroring the
    # never-overwrite rule; clear P12_PATH to re-pull from the vault. The field
    # label `developer-id-p12` parallels the `developer-id-p12-pass` password
    # field — adjust here if the item names the attachment differently.
    if [ -z "$(sed -n 's/^P12_PATH=//p' "$CREDS" | tail -n 1)" ]; then
        local p12dest; p12dest="$(dirname "$CREDS")/developer-id.p12"
        if op read --out-file "$p12dest" "${source}/developer-id-p12" >/dev/null 2>&1 && [ -s "$p12dest" ]; then
            chmod 600 "$p12dest"
            cmd_set P12_PATH "$p12dest"
            filled="$filled P12_PATH"
        else
            rm -f "$p12dest"
        fi
    fi
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
    [ ! -f "$CREDS" ] || die "$CREDS already exists — refusing to overwrite"
    umask 077
    mkdir -p "$(dirname "$CREDS")"
    cat > "$CREDS" <<'EOF'
# Glimmer signing credentials — keep mode 0600, OUTSIDE the repo.
# Read/written ONLY by scripts/signing-creds.sh (see its header for the rules).
# One KEY=VALUE per line; the value is everything after the first '=' (no
# quotes — they would become part of the value).

# Absolute path to the Developer ID Application cert+key exported as .p12
# (Keychain Access → My Certificates → export, or your password manager).
P12_PATH=
# Passphrase chosen at .p12 export time.
P12_PASSWORD=
# Apple ID email the app-specific password belongs to.
APPLE_ID=
# App-specific password for notarytool (appleid.apple.com → App-Specific
# Passwords). Re-run `make setup-notary` after rotating it.
APPLE_APP_PASSWORD=
# Optional: 10-char team id. Leave empty to derive it from the cert name.
#APPLE_TEAM_ID=

# Optional: 1Password item REFERENCE for auto-fill (a pointer, not a secret).
# With this set, `make dist` fetches any EMPTY keys above via `op read`
# (1Password will ask for approval). Expected item fields:
#   username → APPLE_ID, glimmer-app-pass → APPLE_APP_PASSWORD,
#   team-id → APPLE_TEAM_ID, developer-id-p12-pass → P12_PASSWORD, and a FILE
#   field developer-id-p12 (the .p12 itself) → materialized to P12_PATH.
#OP_SOURCE=op://<vault>/<item>     e.g. op://private/apple-developer-creds

# Filled in automatically by `make codesign-setup` / `make dev-sign-setup`:
#SIGN_KEYCHAIN_PASSWORD=
#DEV_KEYCHAIN_PASSWORD=
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
