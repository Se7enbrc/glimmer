#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io
set -euo pipefail

cd "$(dirname "$0")/.."
python3 scripts/check-journey-silence.py --mac
derived="${JOURNEY_DERIVED:-$PWD/build/controller-journeys}"
results="${JOURNEY_RESULTS:-$PWD/build/controller-journey-results}"
mkdir -p "$results"
started=$SECONDS
appearances=(light dark)
case "${JOURNEY_APPEARANCE:-all}" in
    light|dark) appearances=("$JOURNEY_APPEARANCE") ;;
    all) ;;
    *) echo 'JOURNEY_APPEARANCE must be light, dark or all' >&2; exit 2 ;;
esac
selection=(-only-testing:GlimmerUITests)
if [ -n "${JOURNEY_TEST_FLAGS:-}" ]; then read -r -a selection <<< "$JOURNEY_TEST_FLAGS"; fi
for flag in "${selection[@]}"; do
    case "$flag" in
        -only-testing:GlimmerUITests|-only-testing:GlimmerUITests/*) ;;
        *) echo 'JOURNEY_TEST_FLAGS must select only GlimmerUITests' >&2; exit 2 ;;
    esac
done
build=(xcodebuild -project Glimmer.xcodeproj -scheme Glimmer-Controller-Journeys
    -configuration Debug -xcconfig Glimmer/StreamLib.xcconfig -derivedDataPath "$derived"
    -destination platform=macOS CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
    CODE_SIGN_ENTITLEMENTS="$PWD/GlimmerUITests/Journey.entitlements" DEVELOPMENT_TEAM=
    PRODUCT_BUNDLE_IDENTIFIER=io.ugfugl.Glimmer.JourneyHost)
if [ "${JOURNEY_SKIP_BUILD:-0}" != 1 ]; then
    "${build[@]}" -only-testing:GlimmerUITests build-for-testing
fi
status=0
for appearance in "${appearances[@]}"; do
    python3 scripts/check-journey-silence.py --mac
    result="$results/mac-$appearance-$(date +%Y%m%d-%H%M%S).xcresult"
    "${build[@]}" "${selection[@]}" test-without-building JOURNEY_APPEARANCE="$appearance" -parallel-testing-enabled NO \
        -collect-test-diagnostics never -test-timeouts-enabled YES -default-test-execution-time-allowance 180 \
        -resultBundlePath "$result" || status=1
    xcrun xcresulttool export attachments --path "$result" --output-path "${result%.xcresult}-shots" || status=1
done
printf 'Mac controller journeys: %s seconds, results: %s\n' "$((SECONDS - started))" "$results"
exit "$status"
