#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io
set -euo pipefail

cd "$(dirname "$0")/.."
derived="${JOURNEY_DERIVED:-$PWD/iOS/build/touch-journeys}"
results="${JOURNEY_RESULTS:-$PWD/iOS/build/touch-journey-results}"
runtime="${JOURNEY_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"
mkdir -p "$results"
started=$SECONDS
created=()
devices=("${JOURNEY_PHONE_ID:-}" "${JOURNEY_IPAD_ID:-}")
cleanup() {
    if [ "${#created[@]}" -eq 0 ]; then return; fi
    for device in "${created[@]}"; do
        xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
        xcrun simctl delete "$device" >/dev/null 2>&1 || true
    done
}
trap 'cleanup' EXIT
check_live_silence() {
    if [ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] && [ "${#created[@]}" -gt 0 ]; then
        for owned in "${created[@]}"; do
            if [ "$owned" = "$1" ]; then
                # Disposable hosted devices cannot speak on the user's desktop; tests still assert VoiceOver is off.
                echo 'Hosted disposable Simulator: pre-boot speech checked; VoiceOver checked by tests.'
                return
            fi
        done
    fi
    python3 scripts/check-journey-silence.py --simulator "$1" --booted
}
types=(iPhone-17-Pro iPad-Pro-11-inch-M5-12GB)
indices=(0 1)
case "${JOURNEY_DEVICE:-all}" in
    phone) indices=(0) ;;
    ipad) indices=(1) ;;
    all) ;;
    *) echo 'JOURNEY_DEVICE must be phone, ipad or all' >&2; exit 2 ;;
esac
appearances=(light dark)
case "${JOURNEY_APPEARANCE:-all}" in
    light|dark) appearances=("$JOURNEY_APPEARANCE") ;;
    all) ;;
    *) echo 'JOURNEY_APPEARANCE must be light, dark or all' >&2; exit 2 ;;
esac
if [ -n "${JOURNEY_TEST_FLAGS:-}" ]; then
    read -r -a selected_tests <<< "$JOURNEY_TEST_FLAGS"
    for flag in "${selected_tests[@]}"; do
        case "$flag" in
            -only-testing:GlimmerUITests/*) ;;
            *) echo 'JOURNEY_TEST_FLAGS must select only GlimmerUITests' >&2; exit 2 ;;
        esac
    done
fi
for index in "${indices[@]}"; do
    if [ -z "${devices[$index]}" ]; then
        devices[index]="$(xcrun simctl create "Touch journeys ${types[$index]} $$" \
            "com.apple.CoreSimulator.SimDeviceType.${types[$index]}" "$runtime")"
        created+=("${devices[$index]}")
    fi
    python3 scripts/check-journey-silence.py --simulator "${devices[$index]}"
done
if [ "${JOURNEY_SKIP_BUILD:-0}" != 1 ]; then
    make -C iOS test-build SCHEME=Glimmer-Touch-Journeys DERIVED="$derived" \
        TEST_DESTINATION="platform=iOS Simulator,id=${devices[${indices[0]}]}" \
        TEST_FLAGS='-only-testing:GlimmerUITests'
fi
status=0
for index in "${indices[@]}"; do
    device="${devices[$index]}"
    selection="-only-testing:GlimmerUITests/TouchJourneyUITests -only-testing:GlimmerUITests/ControllerJourneyUITests"
    if [ "$index" -eq 1 ]; then selection+=" -only-testing:GlimmerUITests/IPadTouchJourneyUITests"; fi
    if [ -n "${JOURNEY_TEST_FLAGS:-}" ]; then selection="$JOURNEY_TEST_FLAGS"; fi
    for appearance in "${appearances[@]}"; do
        # Already checked before the build; finish booting first so the live speech check can reach it.
        xcrun simctl bootstatus "$device" -b
        check_live_silence "$device"
        xcrun simctl uninstall "$device" io.ugfugl.Glimmer.iOS.UITests.xctrunner >/dev/null 2>&1 || true
        xcrun simctl uninstall "$device" io.ugfugl.Glimmer.iOS >/dev/null 2>&1 || true
        xcrun simctl ui "$device" appearance "$appearance"
        result="$results/device-$index-$appearance-$(date +%Y%m%d-%H%M%S).xcresult"
        make -C iOS test-run SCHEME=Glimmer-Touch-Journeys DERIVED="$derived" TEST_DESTINATION="platform=iOS Simulator,id=$device" \
            TEST_FLAGS="$selection -collect-test-diagnostics never -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -resultBundlePath $result" || status=1
        xcrun xcresulttool export attachments --path "$result" --output-path "${result%.xcresult}-shots" || status=1
    done
done
printf 'Touch journeys: %s seconds, results: %s\n' "$((SECONDS - started))" "$results"
cleanup
trap - EXIT
exit "$status"
