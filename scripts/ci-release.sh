#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

# Hosted release entry points. Credentials exist only for their individual phase.
set +x
set -euo pipefail

die() { echo "ERR: $*" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]] || die "not a workflow run"
[[ "${RUNNER_TEMP:-}" = /* && -d "$RUNNER_TEMP" ]] || die "missing runner temporary directory"
PRIVATE="$RUNNER_TEMP/glimmer-release-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
STAMP="$RUNNER_TEMP/glimmer-verified-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
BUILT="$STAMP-built"
SIGNED="$STAMP-signed"
PACKAGED="$STAMP-packaged"
ARTIFACTS="$PACKAGED-artifacts"
GREEN="$STAMP-green"
PROMOTED="$STAMP-promoted"
PROMOTION="$RUNNER_TEMP/glimmer-promotion-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
KEYCHAIN="$PRIVATE/signing.keychain-db"
APP="$ROOT/build/Build/Products/Release/Glimmer.app"
VERSION="$(sed -n 's/^MARKETING_VERSION = //p' Glimmer/Version.xcconfig | tr -d ' ')"
DMG="$ROOT/build/dist/Glimmer-$VERSION.dmg"
ZIP="$ROOT/build/dist/Glimmer-$VERSION.zip"
OPERATION="${RELEASE_OPERATION:-candidate}"
export GLIMMER_RELEASE_CHANNEL=rc

cleanup() {
    local result=0
    if [ -e "$KEYCHAIN" ]; then
        security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || result=$?
    fi
    rm -rf "$PRIVATE" || result=$?
    [ "$result" -eq 0 ] || echo "ERR: temporary release credential cleanup failed" >&2
    return "$result"
}

finish() {
    local result=$? cleanup_result=0
    trap - EXIT
    cleanup || cleanup_result=$?
    [ "$result" -ne 0 ] || result=$cleanup_result
    exit "$result"
}

check_context() {
    [ "${GITHUB_ACTIONS:-}" = true ] && [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ] || die "manual Actions release required"
    [ "${GITHUB_REPOSITORY:-}" = Se7enbrc/glimmer ] || die "release requires upstream repository"
    case "$OPERATION:${GITHUB_REF:-}" in
        candidate:refs/heads/release-candidate|promote:refs/heads/main) ;;
        *) die "candidate requires release-candidate branch; promotion requires main" ;;
    esac
    [[ "${RC_TAG:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-rc\.[1-9][0-9]*$ ]] &&
        [ "${RC_TAG%-rc.*}" = "$VERSION" ] || die "invalid candidate tag"
    [[ "${EXPECTED_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "expected_sha must be a full lowercase commit SHA"
    [ "${GITHUB_SHA:-}" = "$EXPECTED_SHA" ] || die "dispatch SHA differs from reviewed SHA"
    [ "${RUNNER_DEBUG:-0}" != 1 ] || die "disable Actions debug logging for release"
    local debug
    for debug in "${ACTIONS_STEP_DEBUG:-false}" "${ACTIONS_RUNNER_DEBUG:-false}"; do
        case "$debug" in [tT][rR][uU][eE]) die "disable Actions debug logging for release" ;; esac
    done
}

check_source() {
    check_context
    [ "$(git rev-parse HEAD)" = "$EXPECTED_SHA" ] || die "checkout differs from reviewed SHA"
    [ "$(git remote get-url origin)" = https://github.com/Se7enbrc/glimmer ] ||
        [ "$(git remote get-url origin)" = https://github.com/Se7enbrc/glimmer.git ] || die "unexpected origin"
    local branch="${GITHUB_REF#refs/heads/}"
    git fetch --quiet origin "$branch"
    [ "$(git rev-parse "origin/$branch")" = "$EXPECTED_SHA" ] || die "source branch moved; review and dispatch its new SHA"
    if [ "$OPERATION" = candidate ]; then
        git fetch --quiet origin "refs/tags/$RC_TAG" || die "maintainer must create the reviewed candidate tag first"
        [ "$(git rev-parse 'FETCH_HEAD^{commit}')" = "$EXPECTED_SHA" ] || die "candidate tag identifies different source"
    fi
    make --no-print-directory guard-clean-tree
}

require_verified() {
    check_source
    [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$EXPECTED_SHA" ] || die "this SHA has not passed verification in this run"
}

require_phase() {
    require_verified
    [ -f "$1" ] && [ "$(cat "$1")" = "$EXPECTED_SHA" ] || die "required release phase has not succeeded in this run"
    [ -x "$APP/Contents/MacOS/Glimmer" ] && [ -f "$APP/Contents/Info.plist" ] || die "built app missing"
    local helper="$APP/Contents/Library/LaunchServices/Glimmer Network Helper.app/Contents"
    [ -x "$helper/MacOS/io.ugfugl.glimmer.helper" ] && [ -f "$helper/Info.plist" ] || die "built helper missing"
}

private_directory() {
    umask 077
    mkdir "$PRIVATE"
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

require_packaged_bytes() {
    [ -s "$DMG" ] && [ -s "$ZIP" ] || die "packaged release asset missing"
    [ -s "$ARTIFACTS" ] || die "packaged release digests missing"
    shasum -a 256 "$DMG" "$ZIP" | cmp -s "$ARTIFACTS" - || die "packaged release assets changed"
}

write_signing_files() {
    python3 - "$PRIVATE" <<'PY'
import base64, os, pathlib, secrets, sys
root = pathlib.Path(sys.argv[1])
files = {"DEVELOPER_ID_P12_BASE64": "identity.p12", "NOTARY_KEY_BASE64": "notary.p8",
         "APP_PROVISIONPROFILE_BASE64": "app.provisionprofile",
         "HELPER_PROVISIONPROFILE_BASE64": "helper.provisionprofile"}
values = {}
for key in (*files, "P12_PASSWORD", "NOTARY_KEY_ID", "NOTARY_ISSUER_ID"):
    value = os.environ.get(key, "")
    if not value or "\n" in value or "\r" in value:
        sys.exit(f"ERR: missing or multiline {key}")
    values[key] = value
for key, name in files.items():
    try:
        data = base64.b64decode(values[key], validate=True)
    except ValueError:
        sys.exit(f"ERR: invalid base64 in {key}")
    if not data:
        sys.exit(f"ERR: empty {key}")
    if key == "NOTARY_KEY_BASE64":
        try:
            pem = data.decode("utf-8")
        except UnicodeDecodeError:
            sys.exit("ERR: notarization key is not UTF-8")
        masked = pem.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::add-mask::{masked}", flush=True)
    (root / name).write_bytes(data)
password = secrets.token_urlsafe(32)
print(f"::add-mask::{password}")
entries = {"P12_PATH": str(root / "identity.p12"), "P12_PASSWORD": values["P12_PASSWORD"],
           "NOTARY_KEY_PATH": str(root / "notary.p8"), "NOTARY_KEY_ID": values["NOTARY_KEY_ID"],
           "NOTARY_ISSUER_ID": values["NOTARY_ISSUER_ID"], "SIGN_KEYCHAIN_PASSWORD": password}
(root / "signing.env").write_text("".join(f"{key}={value}\n" for key, value in entries.items()))
PY
}

publish_credentials() {
    [ -n "${RELEASE_CONTENTS_TOKEN:-}" ] || die "missing release contents token"
    export GH_TOKEN="$RELEASE_CONTENTS_TOKEN"
    cat > "$PRIVATE/git-credential" <<'HELPER'
#!/bin/bash
set +x
[ "$1" = get ] || exit 0
protocol= host=
while IFS='=' read -r key value; do
    case "$key" in protocol) protocol="$value" ;; host) host="$value" ;; esac
done
[ "$protocol" = https ] && [ "$host" = github.com ] || exit 0
printf 'username=x-access-token\npassword=%s\n' "$RELEASE_CONTENTS_TOKEN"
HELPER
    chmod 700 "$PRIVATE/git-credential"
    export GIT_CONFIG_COUNT=4
    export GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
    export GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1="$PRIVATE/git-credential"
    export GIT_CONFIG_KEY_2=user.name GIT_CONFIG_VALUE_2=Se7enbrc
    export GIT_CONFIG_KEY_3=user.email GIT_CONFIG_VALUE_3=Se7enbrc@users.noreply.github.com
    export GIT_TERMINAL_PROMPT=0
}

case "${1:-}" in
    check) check_source ;;
    checks)
        check_source
        rm -f "$GREEN"
        python3 scripts/release-checks.py "$EXPECTED_SHA"
        printf '%s\n' "$EXPECTED_SHA" > "$GREEN"
        ;;
    verify)
        check_source
        [ "$OPERATION" = candidate ] || die "promotion never builds"
        [ -f "$GREEN" ] && [ "$(cat "$GREEN")" = "$EXPECTED_SHA" ] || die "required checks have not passed"
        rm -f "$STAMP" "$BUILT" "$SIGNED" "$PACKAGED" "$ARTIFACTS"
        GLIMMER_SECRET_SCAN_ALL_FILES=1 pre-commit run --all-files
        make verify
        check_source
        printf '%s\n' "$EXPECTED_SHA" > "$STAMP"
        ;;
    build)
        [ "$OPERATION" = candidate ] || die "promotion never builds"
        rm -f "$BUILT" "$SIGNED" "$PACKAGED" "$ARTIFACTS"
        require_verified
        make CONFIG=Release guard-release-version clean app embed-helper
        check_source
        printf '%s\n' "$EXPECTED_SHA" > "$BUILT"
        ;;
    sign)
        [ "$OPERATION" = candidate ] || die "promotion never signs"
        rm -f "$SIGNED" "$PACKAGED" "$ARTIFACTS"
        require_phase "$BUILT"
        private_directory
        write_signing_files
        unset DEVELOPER_ID_P12_BASE64 P12_PASSWORD NOTARY_KEY_BASE64 NOTARY_KEY_ID NOTARY_ISSUER_ID
        unset APP_PROVISIONPROFILE_BASE64 HELPER_PROVISIONPROFILE_BASE64
        export SIGNING_CREDS="$PRIVATE/signing.env" SIGN_KEYCHAIN="$KEYCHAIN"
        export PROVISIONING_PROFILE="$PRIVATE/app.provisionprofile"
        export HELPER_PROVISIONING_PROFILE="$PRIVATE/helper.provisionprofile"
        make codesign-setup setup-notary
        # Compilation and helper embedding already succeeded without credentials.
        make CONFIG=Release -o app -o embed-helper preflight notarize
        cleanup
        printf '%s\n' "$EXPECTED_SHA" > "$SIGNED"
        ;;
    package)
        [ "$OPERATION" = candidate ] || die "promotion never packages"
        rm -f "$PACKAGED" "$ARTIFACTS"
        require_phase "$SIGNED"
        [ ! -e "$PRIVATE" ] || die "signing credentials have not been removed"
        [ -n "${GITHUB_OUTPUT:-}" ] || die "workflow output file missing"
        make CONFIG=Release dmg sparkle-zip
        [ -s "$DMG" ] && [ -s "$ZIP" ] || die "packaged release asset missing"
        shasum -a 256 "$DMG" "$ZIP" > "$ARTIFACTS"
        printf 'dmg-path=%s\nzip-path=%s\n' "$DMG" "$ZIP" >> "$GITHUB_OUTPUT"
        printf '%s\n' "$EXPECTED_SHA" > "$PACKAGED"
        ;;
    publish)
        [ "$OPERATION" = candidate ] || die "use the promotion phase"
        require_phase "$PACKAGED"
        require_packaged_bytes
        [[ "${RELEASE_ATTESTATION_ID:-}" =~ ^[0-9]+$ ]] || die "release artifact attestation missing"
        private_directory
        publish_credentials
        python3 - "$PRIVATE/signing.env" <<'PY'
import os, pathlib, sys
key = os.environ.get("SPARKLE_ED_PRIVATE_KEY", "")
if not key or "\n" in key or "\r" in key:
    sys.exit("ERR: missing or multiline Sparkle key")
pathlib.Path(sys.argv[1]).write_text(f"SPARKLE_ED_PRIVATE_KEY={key}\n")
PY
        unset SPARKLE_ED_PRIVATE_KEY
        export GLIMMER_SIGNING_CREDS="$PRIVATE/signing.env"
        BUILD="$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' Glimmer/Version.xcconfig | tr -d ' ')"
        scripts/publish-release.sh "$VERSION" "$BUILD" "$ROOT/build/Build/Products/Release/Glimmer.app" "$ROOT/build/dist" Se7enbrc/glimmer "$RC_TAG"
        ;;
    prepare-promotion)
        check_source
        [ "$OPERATION" = promote ] || die "promotion requires main"
        [ -f "$GREEN" ] && [ "$(cat "$GREEN")" = "$EXPECTED_SHA" ] || die "required checks have not passed"
        python3 scripts/promote-release.py prepare "$RC_TAG" "${CANDIDATE_SHA:-}"
        ;;
    promote)
        check_source
        [ "$OPERATION" = promote ] || die "promotion requires main"
        [ -f "$GREEN" ] && [ "$(cat "$GREEN")" = "$EXPECTED_SHA" ] || die "required checks have not passed"
        python3 scripts/promote-release.py validate "$RC_TAG" "${CANDIDATE_SHA:-}"
        private_directory
        publish_credentials
        python3 scripts/promote-release.py publish "$RC_TAG" "${CANDIDATE_SHA:-}"
        printf '%s %s\n' "$EXPECTED_SHA" "$RC_TAG" > "$PROMOTED"
        ;;
    tap)
        check_context
        [ "$OPERATION" = promote ] || die "candidates never update Homebrew"
        [ -f "$PROMOTED" ] && [ "$(cat "$PROMOTED")" = "$EXPECTED_SHA $RC_TAG" ] || die "candidate has not been promoted in this run"
        private_directory
        publish_credentials
        export GLIMMER_TAP_CACHE="$PRIVATE/tap"
        git clone --quiet https://github.com/Se7enbrc/homebrew-glimmer.git "$GLIMMER_TAP_CACHE"
        scripts/homebrew-bump.sh "$VERSION" "$RC_TAG"
        ;;
    cleanup)
        result=0
        cleanup || result=$?
        rm -rf "$PROMOTION" || result=$?
        exit "$result"
        ;;
    *) die "usage: ci-release.sh check|checks|verify|build|sign|package|publish|prepare-promotion|promote|tap|cleanup" ;;
esac
