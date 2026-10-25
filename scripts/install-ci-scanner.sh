#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

# Keep hosted scans on the reviewed scanner version, independent of runner images.
set -euo pipefail

[[ "${CI:-}" == true ]] || { echo "ERROR: scanner installation requires CI." >&2; exit 1; }
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) platform=darwin_arm64; SHA256=b8a3f496ec10f213bd2d2ad276625a773a2b284b5cc84993d24fc27db00d3493 ;;
    Linux-x86_64) platform=linux_amd64; SHA256=8f71019bcb8c6c44242b6e34f68c3755f8f9c8496d3063b7a8b5626fb9bff220 ;;
    *) echo "ERROR: unsupported scanner platform." >&2; exit 1 ;;
esac
[[ "${RUNNER_TEMP:-}" == /* && -d "$RUNNER_TEMP" &&
   "${GITHUB_PATH:-}" == /* && -f "$GITHUB_PATH" && -w "$GITHUB_PATH" ]] || {
    echo "ERROR: scanner installation requires runner temporary and PATH files." >&2; exit 1;
}

WORK="$(mktemp -d "${RUNNER_TEMP%/}/glimmer-scanner.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ARCHIVE="$WORK/trufflehog.tar.gz"
URL=https://github.com/trufflesecurity/trufflehog/releases/download/v3.97.8/trufflehog_3.97.8_${platform}.tar.gz
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --output "$ARCHIVE" "$URL"
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 --check --status
# Only the verified executable is extracted; release metadata stays in the archive.
tar -xzf "$ARCHIVE" -C "$WORK" trufflehog
BIN="${RUNNER_TEMP%/}/glimmer-tools/bin"
mkdir -p "$BIN"
install -m 755 "$WORK/trufflehog" "$BIN/trufflehog"
printf '%s\n' "$BIN" >> "$GITHUB_PATH"
