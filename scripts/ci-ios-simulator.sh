#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

# Prints an xcodebuild destination for an iPhone simulator, creating one first if the
# runner image has none. Hosted images sometimes ship without an iOS runtime for the
# pinned Xcode, so the runtime is downloaded as a last resort.
set -euo pipefail

DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
NAME="Glimmer CI iPhone"
SDK_VERSION=$(xcrun --sdk iphonesimulator --show-sdk-version)

matching_runtime() {
	xcrun simctl list runtimes --json | python3 -c '
import json, sys
def version(value):
    parts = [int(p) for p in value.split(".")]
    return (parts + [0, 0])[:3]
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("platform") == "iOS" and r.get("isAvailable")
            and version(r["version"]) == version(sys.argv[1])]
print(runtimes[0]["identifier"] if runtimes else "")' "$SDK_VERSION"
}

existing_iphone() {
	xcrun simctl list devices available --json | python3 -c '
import json, sys
for device in json.load(sys.stdin)["devices"].get(sys.argv[1], []):
    if device.get("deviceTypeIdentifier") == sys.argv[2]:
        print(device["udid"]); break' "$runtime" "$DEVICE_TYPE"
}

runtime=$(matching_runtime)
if [ -z "$runtime" ]; then
	echo "No iOS $SDK_VERSION Simulator runtime for the active Xcode; downloading it" >&2
	xcodebuild -downloadPlatform iOS >&2
	runtime=$(matching_runtime)
fi
[ -n "$runtime" ] || { echo "ERR: no iOS $SDK_VERSION Simulator runtime available" >&2; exit 1; }
udid=$(existing_iphone)
if [ -z "$udid" ]; then
	udid=$(xcrun simctl create "$NAME" "$DEVICE_TYPE" "$runtime")
	echo "Created $NAME ($udid) on $runtime" >&2
fi
echo "platform=iOS Simulator,id=$udid"
