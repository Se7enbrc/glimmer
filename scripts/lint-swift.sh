#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

set -euo pipefail
if [ "$(uname -s)" = Linux ]; then
    toolchain=$(dirname "$(dirname "$(readlink -f "$(command -v swift)")")")
    export LINUX_SOURCEKIT_LIB_PATH="$toolchain/lib/libsourcekitdInProc.so"
    test -f "$LINUX_SOURCEKIT_LIB_PATH"
    export LD_LIBRARY_PATH="$toolchain/lib/swift/linux${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
cd "$(dirname "$0")/.."
# Explicit configurations keep path scopes separate while sharing one rule set.
swiftlint "$@" --config .swiftlint.yml
if [ -f iOS/.swiftlint.yml ]; then (cd iOS && swiftlint "$@" --config .swiftlint.yml); fi
