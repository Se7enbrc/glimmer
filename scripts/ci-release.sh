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
PROMOTION="$RUNNER_TEMP/glimmer-promotion-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
KEYCHAIN="$PRIVATE/signing.keychain-db"
APP="$ROOT/build/Build/Products/Release/Glimmer.app"
export RELEASE_VERSION_CONFIG="${RELEASE_VERSION_CONFIG:-$ROOT/Glimmer/Version.xcconfig}"
if [ -n "${TRUSTED_TOOLING_SHA:-}" ] && [ "${1:-}" != cleanup ]; then
    [[ "${EXPECTED_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "invalid source SHA"
    export RELEASE_VERSION_CONFIG="$RUNNER_TEMP/glimmer-version-$GITHUB_RUN_ID.xcconfig"
    git show "$EXPECTED_SHA:Glimmer/Version.xcconfig" > "$RELEASE_VERSION_CONFIG"
fi
VERSION="$(sed -n 's/^MARKETING_VERSION = //p' "$RELEASE_VERSION_CONFIG" | tr -d ' ')"
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
    [ "${GITHUB_ACTIONS:-}" = true ] && [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ] ||
        die "manual Actions release required"
    [ "${GITHUB_REPOSITORY:-}" = Se7enbrc/glimmer ] || die "release requires upstream repository"
    case "$OPERATION:${GITHUB_REF:-}" in
        candidate:refs/heads/release-candidate|promote:refs/heads/main) ;;
        *) die "candidate requires release-candidate branch; promotion requires main" ;;
    esac
    [[ "${RC_TAG:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-rc\.[1-9][0-9]*(-diag)?$ ]] &&
        [ "${RC_TAG%-rc.*}" = "$VERSION" ] || die "invalid candidate tag"
    if [[ "$RC_TAG" = *-diag ]] && [ "$OPERATION" = promote ]; then
        die "diagnostic candidates cannot be promoted"
    fi
    [[ "${EXPECTED_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "expected_sha must be a full lowercase commit SHA"
    if [ -n "${TRUSTED_TOOLING_SHA:-}" ]; then
        [[ "$TRUSTED_TOOLING_SHA" =~ ^[0-9a-f]{40}$ ]] || die "invalid trusted tooling SHA"
    fi
    [ "${GITHUB_SHA:-}" = "$EXPECTED_SHA" ] || die "dispatch SHA differs from reviewed SHA"
    [ "${RUNNER_DEBUG:-0}" != 1 ] || die "disable Actions debug logging for release"
    local debug
    for debug in "${ACTIONS_STEP_DEBUG:-false}" "${ACTIONS_RUNNER_DEBUG:-false}"; do
        case "$debug" in [tT][rR][uU][eE]) die "disable Actions debug logging for release" ;; esac
    done
}

check_source() {
    check_context
    [ "$(git rev-parse HEAD)" = "${TRUSTED_TOOLING_SHA:-$EXPECTED_SHA}" ] || die "checkout differs from reviewed SHA"
    [ "$(git remote get-url origin)" = https://github.com/Se7enbrc/glimmer ] ||
        [ "$(git remote get-url origin)" = https://github.com/Se7enbrc/glimmer.git ] || die "unexpected origin"
    if [ -n "${TRUSTED_TOOLING_SHA:-}" ]; then
        git fetch --quiet origin main
        git merge-base --is-ancestor "$TRUSTED_TOOLING_SHA" origin/main ||
            die "trusted tooling is not in main history"
        git diff --quiet "$EXPECTED_SHA" "$TRUSTED_TOOLING_SHA" -- \
            Glimmer/Glimmer.entitlements LoginHelper/LoginHelper.entitlements helper/Helper.entitlements ||
            die "candidate signing policy differs from trusted main"
    fi
    local branch="${GITHUB_REF#refs/heads/}"
    git fetch --quiet origin "$branch"
    [ "$(git rev-parse "origin/$branch")" = "$EXPECTED_SHA" ] ||
        die "source branch moved; review and dispatch its new SHA"
    if [ "$OPERATION" = candidate ]; then
        git fetch --quiet origin "refs/tags/$RC_TAG" || die "maintainer must create the reviewed candidate tag first"
        [ "$(git rev-parse 'FETCH_HEAD^{commit}')" = "$EXPECTED_SHA" ] ||
            die "candidate tag identifies different source"
    fi
    make --no-print-directory guard-clean-tree
}

require_verified() {
    check_source
    [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$EXPECTED_SHA" ] || die "this SHA has not passed verification in this run"
}

verify_part() {
    local part="$1" target started=$SECONDS
    check_source
    [ "$OPERATION" = candidate ] || die "promotion never builds"
    [ -f "$GREEN" ] && [ "$(cat "$GREEN")" = "$EXPECTED_SHA" ] || die "required checks have not passed"
    [ -n "${GITHUB_OUTPUT:-}" ] || die "workflow output file missing"
    case "$part" in
        checks) target=check; GLIMMER_SECRET_SCAN_ALL_FILES=1 pre-commit run --all-files ;;
        tests) target="test" ;;
        asan) target=test-asan ;;
        *) die "unknown verification part" ;;
    esac
    make "$target" "DERIVED=$ROOT/build/verify-$part" TEST_SUITE=
    check_source
    printf 'record=%s %s %s %s\n' "$EXPECTED_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$part" \
        >> "$GITHUB_OUTPUT"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf 'Verification %s: %s, run %s, attempt %s, %ss\n' \
            "$part" "$EXPECTED_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$((SECONDS - started))" \
            >> "$GITHUB_STEP_SUMMARY"
    fi
}

accept_verification() {
    rm -f "$STAMP" "$BUILT" "$SIGNED" "$PACKAGED" "$ARTIFACTS"
    check_source
    [ "$OPERATION" = candidate ] || die "promotion never builds"
    [ -f "$GREEN" ] && [ "$(cat "$GREEN")" = "$EXPECTED_SHA" ] || die "required checks have not passed"
    local part result record name attempt pattern
    for part in checks tests asan; do
        name="$(printf '%s' "$part" | tr '[:lower:]' '[:upper:]')"
        result="VERIFY_${name}_RESULT"
        record="VERIFY_${name}_RECORD"
        [ "${!result:-}" = success ] || die "$part verification did not succeed"
        pattern="^$EXPECTED_SHA $GITHUB_RUN_ID ([1-9][0-9]*) $part$"
        [[ "${!record:-}" =~ $pattern ]] || die "$part verification record differs from this SHA, run or check"
        attempt="${BASH_REMATCH[1]}"
        [ "$attempt" -le "$GITHUB_RUN_ATTEMPT" ] || die "$part verification attempt is in the future"
    done
    printf '%s\n' "$EXPECTED_SHA" > "$STAMP"
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
    export RELEASE_READ_TOKEN="${GH_TOKEN:-}"
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
        check_args=("$EXPECTED_SHA")
        if [ "$OPERATION" = candidate ]; then check_args+=(--candidate); fi
        RELEASE_CHECKS_FILE="$RUNNER_TEMP/glimmer-prerequisites.json" \
            python3 scripts/release-checks.py "${check_args[@]}"
        if [ "$OPERATION" = promote ]; then
            RELEASE_CHECKS_FILE="$RUNNER_TEMP/glimmer-candidate-prerequisites.json" \
                python3 scripts/release-checks.py "${CANDIDATE_SHA:-}" --candidate
        fi
        printf '%s\n' "$EXPECTED_SHA" > "$GREEN"
        ;;
    verify-checks|verify-tests|verify-asan) verify_part "${1#verify-}" ;;
    verified) accept_verification ;;
    build)
        [ "$OPERATION" = candidate ] || die "promotion never builds"
        rm -f "$BUILT" "$SIGNED" "$PACKAGED" "$ARTIFACTS"
        require_verified
        export XCODE_XCCONFIG_FILE="${XCODE_XCCONFIG_FILE:-$RUNNER_TEMP/glimmer-release-build.xcconfig}"
        diagnostic=NO
        [[ "$RC_TAG" != *-diag ]] || diagnostic=YES
        printf '\nGLIMMER_DIAGNOSTIC_BUILD = %s\n' "$diagnostic" >> "$XCODE_XCCONFIG_FILE"
        make CONFIG=Release guard-release-version clean app embed-helper
        python3 scripts/release_candidate_kind.py "$RC_TAG" "$APP"
        check_source
        printf '%s\n' "$EXPECTED_SHA" > "$BUILT"
        ;;
    import-unsigned)
        rm -f "$STAMP" "$BUILT" "$SIGNED" "$PACKAGED" "$ARTIFACTS"
        check_source
        [ "$OPERATION" = candidate ] || die "promotion never imports unsigned code"
        [ -f "$GREEN" ] && [ "$(cat "$GREEN")" = "$EXPECTED_SHA" ] || die "required checks have not passed"
        [ -n "${TRUSTED_TOOLING_SHA:-}" ] || die "signing requires main tooling"
        python3 scripts/release_artifact.py unpack "$RUNNER_TEMP/unsigned" \
            --manifest "${UNSIGNED_MANIFEST:-}" --attempt "${UNSIGNED_ATTEMPT:-}" \
            --destination "$ROOT/build/Build/Products/Release"
        python3 scripts/release_candidate_kind.py "$RC_TAG" "$APP"
        printf '%s\n' "$EXPECTED_SHA" > "$STAMP"
        printf '%s\n' "$EXPECTED_SHA" > "$BUILT"
        ;;
    sign)
        [ "$OPERATION" = candidate ] || die "promotion never signs"
        rm -f "$SIGNED" "$PACKAGED" "$ARTIFACTS"
        require_phase "$BUILT"
        [ -n "${TRUSTED_TOOLING_SHA:-}" ] || die "signing requires main tooling"
        private_directory
        write_signing_files
        unset DEVELOPER_ID_P12_BASE64 P12_PASSWORD NOTARY_KEY_BASE64 NOTARY_KEY_ID NOTARY_ISSUER_ID
        unset APP_PROVISIONPROFILE_BASE64 HELPER_PROVISIONPROFILE_BASE64
        export SIGNING_CREDS="$PRIVATE/signing.env" SIGN_KEYCHAIN="$KEYCHAIN"
        export PROVISIONING_PROFILE="$PRIVATE/app.provisionprofile"
        export HELPER_PROVISIONING_PROFILE="$PRIVATE/helper.provisionprofile"
        make codesign-setup setup-notary
        # Compilation and helper embedding already succeeded without credentials.
        make CONFIG=Release preflight notarize-bundle
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
        check_source
        python3 scripts/release_publication.py check "$RUNNER_TEMP/signed"
        private_directory
        publish_credentials
        python3 scripts/release_publication.py publish "$RUNNER_TEMP/signed"
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
        ;;
    tap)
        check_context
        [ "$OPERATION" = promote ] || die "candidates never update Homebrew"
        check_source
        python3 scripts/promote-release.py validate "$RC_TAG" "${CANDIDATE_SHA:-}"
        [ "$(gh release view "$RC_TAG" -R Se7enbrc/glimmer --json isPrerelease,isDraft \
            --jq '.isPrerelease == false and .isDraft == false')" = true ] || die "release is not stable"
        export RELEASE_READ_TOKEN="${GH_TOKEN:-}"
        export EXPECTED_DMG_SHA256
        EXPECTED_DMG_SHA256="$(shasum -a 256 "$PROMOTION/Glimmer-$VERSION.dmg" | cut -d' ' -f1)"
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
    *) die "usage: ci-release.sh check|checks|verify-{checks,tests,asan}|verified|build|import-unsigned" \
        "|sign|package|publish" \
        "|prepare-promotion|promote|tap|cleanup" ;;
esac
