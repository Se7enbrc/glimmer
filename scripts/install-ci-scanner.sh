#!/bin/bash
# Keep hosted scans on the reviewed scanner version, independent of runner images.
set -euo pipefail

[[ "${CI:-}" == true && "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
    echo "ERROR: scanner installation requires a Darwin arm64 CI runner." >&2; exit 1;
}
[[ "${RUNNER_TEMP:-}" == /* && -d "$RUNNER_TEMP" &&
   "${GITHUB_PATH:-}" == /* && -f "$GITHUB_PATH" && -w "$GITHUB_PATH" ]] || {
    echo "ERROR: scanner installation requires runner temporary and PATH files." >&2; exit 1;
}

WORK="$(mktemp -d "${RUNNER_TEMP%/}/glimmer-scanner.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ARCHIVE="$WORK/trufflehog.tar.gz"
URL=https://github.com/trufflesecurity/trufflehog/releases/download/v3.97.8/trufflehog_3.97.8_darwin_arm64.tar.gz
SHA256=b8a3f496ec10f213bd2d2ad276625a773a2b284b5cc84993d24fc27db00d3493
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --output "$ARCHIVE" "$URL"
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 --check --status
# Only the verified executable is extracted; release metadata stays in the archive.
tar -xzf "$ARCHIVE" -C "$WORK" trufflehog
BIN="${RUNNER_TEMP%/}/glimmer-tools/bin"
mkdir -p "$BIN"
install -m 755 "$WORK/trufflehog" "$BIN/trufflehog"
printf '%s\n' "$BIN" >> "$GITHUB_PATH"
