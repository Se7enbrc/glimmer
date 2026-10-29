#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Refuse to boot or test a Simulator configured to speak."""

import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys


def live_setting(identifier, key):
    live = subprocess.run(["xcrun", "simctl", "spawn", identifier, "defaults", "read",
                           "com.apple.Accessibility", key], capture_output=True, text=True, check=False, timeout=30)
    if live.returncode == 0:
        value = live.stdout.strip().lower()
        if value in {"1", "true", "yes"}:
            return True
        if value in {"0", "false", "no"}:
            return False
    else:
        message = " ".join(live.stderr.split())
        missing = (f"Could not find key '{key}' in domain 'com.apple.Accessibility'",
                   f"The domain/default pair of (com.apple.Accessibility, {key}) does not exist")
        if any(text in message for text in missing):
            return False
    raise RuntimeError(f"Could not verify the Simulator's speech setting: {key}")


def check_simulator(identifier, booted=False):
    preferences = {}
    if not booted:
        result = subprocess.run(["xcrun", "simctl", "list", "devices", "--json"],
                                check=True, capture_output=True, text=True, timeout=30)
        devices = json.loads(result.stdout)["devices"]
        device = next(device for group in devices.values() for device in group if device["udid"] == identifier)
        path = Path(device["dataPath"]) / "Library/Preferences/com.apple.Accessibility.plist"
        preferences = plistlib.loads(path.read_bytes()) if path.exists() else {}
        booted = device["state"] == "Booted"
    for key in ["VoiceOverTouchEnabled", "SpeakScreenEnabled"]:
        enabled = bool(preferences.get(key, False))
        if booted:
            enabled = live_setting(identifier, key) or enabled
        if enabled:
            raise RuntimeError(f"Refusing to run: {key} is enabled in the target Simulator. Turn it off first.")


def check_mac():
    script = 'ObjC.import("AppKit"); $.NSWorkspace.sharedWorkspace.isVoiceOverEnabled'
    result = subprocess.run(["osascript", "-l", "JavaScript", "-e", script],
                            capture_output=True, text=True, check=True, timeout=30)
    if result.stdout.strip() == "true":
        raise RuntimeError("Refusing to run: VoiceOver is enabled on the Mac. Turn it off first.")
    if result.stdout.strip() != "false":
        raise RuntimeError("Could not verify the Mac's speech setting")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--simulator")
    target.add_argument("--mac", action="store_true")
    parser.add_argument("--booted", action="store_true", help="Check live settings after simulator bootstatus succeeds")
    arguments = parser.parse_args()
    if arguments.booted and not arguments.simulator:
        parser.error("--booted requires --simulator")
    try:
        if arguments.mac:
            check_mac()
        else:
            check_simulator(arguments.simulator, arguments.booted)
    except (OSError, ValueError, KeyError, StopIteration, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Journey silence guard: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
