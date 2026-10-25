#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

set -eu
command -v mise >/dev/null 2>&1 || {
    echo 'Missing mise. Run brew install mise, then mise install.' >&2
    exit 1
}
export MISE_AUTO_INSTALL=0
if ! mise which "$1" >/dev/null 2>&1; then
    echo "Missing pinned $1. Run mise install." >&2
    exit 1
fi
exec mise exec -- "$@"
