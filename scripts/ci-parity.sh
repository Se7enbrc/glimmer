#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer
if [ ! -d "$DEVELOPER_DIR" ]; then
    echo "CI parity skipped: Xcode 26.6 is not installed at $DEVELOPER_DIR."
    exit 0
fi
export SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES
export SWIFT_SUPPRESS_WARNINGS=NO
root="$PWD/build/ci-parity"
echo "CI parity: compiling unsigned Mac and iOS apps/tests with Xcode 26.6."
nice -n 15 taskpolicy -c utility make app DERIVED="$root/mac"
nice -n 15 taskpolicy -c utility make test-build helper-build DERIVED="$root/mac"
if [ -f iOS/Makefile ]; then
    nice -n 15 taskpolicy -c utility make -C iOS test-build \
        DERIVED="$root/ios-simulator" TEST_DESTINATION='generic/platform=iOS Simulator'
    nice -n 15 taskpolicy -c utility make -C iOS app CONFIG=Release \
        DERIVED="$root/ios-device" DESTINATION='generic/platform=iOS'
else
    echo 'CI parity: this branch has no iOS app or tests.'
fi
