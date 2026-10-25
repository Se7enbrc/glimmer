#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

set -euo pipefail
test "$(uname -s)-$(uname -m)" = Linux-x86_64
bin="$RUNNER_TEMP/glimmer-tools/bin"
mkdir -p "$bin"
scripts/install-ci-auditor.sh "$bin"
scripts/install-ci-scanner.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL --proto '=https' --proto-redir '=https' \
    https://github.com/realm/SwiftLint/releases/download/0.65.1/swiftlint_linux_amd64.zip -o "$work/swiftlint.zip"
printf '%s  %s\n' caeed6f4a679c35539ffaf124f6c4ab4a8416917f7d8796279dc52b74026059d "$work/swiftlint.zip" | shasum -a 256 --check --status
unzip -q "$work/swiftlint.zip" swiftlint -d "$work"
install -m 755 "$work/swiftlint" "$bin/swiftlint"
curl -fsSL --proto '=https' --proto-redir '=https' \
    https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz -o "$work/actionlint.tgz"
printf '%s  %s\n' 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 "$work/actionlint.tgz" | shasum -a 256 --check --status
tar -xzf "$work/actionlint.tgz" -C "$work" actionlint
install -m 755 "$work/actionlint" "$bin/actionlint"
curl -fsSL --proto '=https' --proto-redir '=https' \
    https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz -o "$work/shellcheck.tar.xz"
printf '%s  %s\n' 8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 "$work/shellcheck.tar.xz" | shasum -a 256 --check --status
tar -xJf "$work/shellcheck.tar.xz" -C "$work" shellcheck-v0.11.0/shellcheck
install -m 755 "$work/shellcheck-v0.11.0/shellcheck" "$bin/shellcheck"
printf '%s\n' "$bin" >> "$GITHUB_PATH"
