#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

# Prints an xcodebuild destination for an iPhone simulator, creating one first if the
# runner image has none. Hosted images sometimes ship without an iOS runtime for the
# pinned Xcode, so the runtime is downloaded as a last resort.
set -euo pipefail

DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
NAME="Glimmer CI iPhone"

newest_runtime() {
	xcrun simctl list runtimes --json | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("platform") == "iOS" and r.get("isAvailable")]
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
print(runtimes[-1]["identifier"] if runtimes else "")'
}

existing_iphone() {
	xcrun simctl list devices available --json | python3 -c '
import json, sys
for runtime, devices in sorted(json.load(sys.stdin)["devices"].items(), reverse=True):
    if ".iOS-" in runtime:
        for device in devices:
            if device["name"].startswith("iPhone"):
                print(device["udid"]); raise SystemExit'
}

udid=$(existing_iphone)
if [ -z "$udid" ]; then
	runtime=$(newest_runtime)
	if [ -z "$runtime" ]; then
		echo "No iOS Simulator runtime on this runner; downloading the one for $(xcodebuild -version | head -1)" >&2
		xcodebuild -downloadPlatform iOS >&2
		runtime=$(newest_runtime)
	fi
	[ -n "$runtime" ] || { echo "ERR: no iOS Simulator runtime available" >&2; exit 1; }
	udid=$(xcrun simctl create "$NAME" "$DEVICE_TYPE" "$runtime")
	echo "Created $NAME ($udid) on $runtime" >&2
fi
echo "platform=iOS Simulator,id=$udid"
