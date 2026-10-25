#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

set -euo pipefail
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) platform=aarch64-apple-darwin; checksum=ad5aa633cd56215b11e6c51d51f90c7e6b22904a75047d1215abbd422f61d698 ;;
    Linux-x86_64) platform=x86_64-unknown-linux-gnu; checksum=d185f726bdaf92df78273217dfdd24ebcd6b0ef48cf3ce776ff5762b6e138c99 ;;
    *) echo "Unsupported auditor platform" >&2; exit 1 ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    "https://github.com/zizmorcore/zizmor/releases/download/v1.31.1/zizmor-$platform.tar.gz" -o "$work/auditor.tgz"
printf '%s  %s\n' "$checksum" "$work/auditor.tgz" | shasum -a 256 --check --status
tar -xzf "$work/auditor.tgz" -C "$work" zizmor
install -m 755 "$work/zizmor" "${1:?Pass an existing binary directory}/zizmor"
