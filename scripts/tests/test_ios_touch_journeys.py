# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Exercise journey orchestration without starting Simulator or building an app."""

import json
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
name = Path(sys.argv[0]).name
with open(os.environ["JOURNEY_TEST_LOG"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps([name, *args]) + "\\n")
if name == "xcrun" and args[:2] == ["simctl", "create"]:
    print("created-phone" if "iPhone" in args[2] else "created-pad")
if name == "xcrun" and args == ["simctl", "list", "devices", "--json"]:
    state = "Booted" if os.environ.get("JOURNEY_TEST_BOOTED") else "Shutdown"
    devices = [{"udid": identifier, "dataPath": os.environ["JOURNEY_TEST_DATA"], "state": state}
               for identifier in ["created-phone", "created-pad", "supplied-phone", "supplied-pad"]]
    print(json.dumps({"devices": {"runtime": devices}}))
if name == "xcrun" and args[:2] == ["simctl", "spawn"]:
    sys.exit(f"Error: Could not find key '{args[-1]}' in domain '{args[-2]}'.")
if name == "make" and "test-run" in args and os.environ.get("JOURNEY_TEST_FAIL"):
    if "-dark-" in " ".join(args):
        sys.exit(1)
'''


class IOSTouchJourneyTests(unittest.TestCase):
    def run_journeys(self, *, supplied=False, fail=False, speech=False, booted=False, device="all",
                     appearance="all"):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            binaries = directory / "bin"
            binaries.mkdir()
            for name in ["make", "xcrun"]:
                tool = binaries / name
                tool.write_text(TOOL)
                tool.chmod(0o755)
            log = directory / "calls.jsonl"
            environment = dict(os.environ)
            for key in ["JOURNEY_PHONE_ID", "JOURNEY_IPAD_ID", "JOURNEY_TEST_FAIL", "JOURNEY_TEST_BOOTED"]:
                environment.pop(key, None)
            environment.update({
                "PATH": str(binaries) + os.pathsep + environment["PATH"],
                "JOURNEY_TEST_LOG": str(log),
                "JOURNEY_DERIVED": str(directory / "build"),
                "JOURNEY_RESULTS": str(directory / "results"),
                "JOURNEY_TEST_DATA": str(directory),
                "JOURNEY_DEVICE": device, "JOURNEY_APPEARANCE": appearance,
            })
            if speech:
                preferences = directory / "Library/Preferences"
                preferences.mkdir(parents=True)
                (preferences / "com.apple.Accessibility.plist").write_bytes(
                    plistlib.dumps({"VoiceOverTouchEnabled": True}))
            if supplied:
                environment.update(JOURNEY_PHONE_ID="supplied-phone", JOURNEY_IPAD_ID="supplied-pad")
            if fail:
                environment["JOURNEY_TEST_FAIL"] = "1"
            if booted:
                environment["JOURNEY_TEST_BOOTED"] = "1"
            result = subprocess.run(["/bin/bash", str(ROOT / "scripts/ios-touch-journeys.sh")],
                                    env=environment, text=True, capture_output=True, check=False)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            return result, calls

    def test_build_once_run_four_destinations_and_delete_only_owned_devices(self):
        result, calls = self.run_journeys()
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [call for call in calls if call[0] == "make" and "test-build" in call]
        runs = [call for call in calls if call[0] == "make" and "test-run" in call]
        self.assertEqual(len(builds), 1)
        self.assertEqual(len(runs), 4)
        self.assertTrue(all("ControllerJourneyUITests" in " ".join(call) for call in runs))
        self.assertTrue(all("SCHEME=Glimmer-Touch-Journeys" in call for call in builds + runs))
        self.assertEqual(sum("IPadTouchJourneyUITests" in " ".join(call) for call in runs), 2)
        appearances = [call[-1] for call in calls if call[:3] == ["xcrun", "simctl", "ui"]]
        self.assertEqual(appearances, ["light", "dark", "light", "dark"])
        deleted = [call[-1] for call in calls if call[:3] == ["xcrun", "simctl", "delete"]]
        self.assertEqual(deleted, ["created-phone", "created-pad"])

    def test_failure_keeps_remaining_runs_and_preserves_supplied_devices(self):
        result, calls = self.run_journeys(supplied=True, fail=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(sum(call[0] == "make" and "test-run" in call for call in calls), 4)
        self.assertEqual(sum(call[:3] == ["xcrun", "xcresulttool", "export"] for call in calls), 4)
        self.assertFalse(any(call[:3] == ["xcrun", "simctl", "create"] for call in calls))
        self.assertFalse(any(call[:3] == ["xcrun", "simctl", "delete"] for call in calls))
        self.assertIn("Touch journeys:", result.stdout)

    def test_ci_shard_runs_only_selected_device_and_appearance(self):
        result, calls = self.run_journeys(device="ipad", appearance="dark")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(call[:3] == ["xcrun", "simctl", "create"] for call in calls), 1)
        runs = [call for call in calls if call[0] == "make" and "test-run" in call]
        self.assertEqual(len(runs), 1)
        self.assertIn("id=created-pad", " ".join(runs[0]))
        self.assertIn("-dark-", " ".join(runs[0]))

    def test_booted_simulator_without_speech_keys_runs_every_appearance(self):
        result, calls = self.run_journeys(booted=True, device="phone")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(call[0] == "make" and "test-run" in call for call in calls), 2)

    def test_voiceover_refuses_to_build_or_boot(self):
        result, calls = self.run_journeys(speech=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("VoiceOverTouchEnabled is enabled", result.stderr)
        self.assertFalse(any(call[0] == "make" for call in calls))
        self.assertFalse(any(call[:3] == ["xcrun", "simctl", "bootstatus"] for call in calls))

    def test_ci_scheme_skips_every_journey_class(self):
        # CI's Simulator shards run Glimmer-iOS; journeys belong to their own scheme and time budget.
        scheme = (ROOT / "iOS/Glimmer.xcodeproj/xcshareddata/xcschemes/Glimmer-iOS.xcscheme").read_text()
        classes = {path.stem for path in (ROOT / "iOS/GlimmerUITests").glob("*JourneyUITests.swift")
                   if f"final class {path.stem}" in path.read_text()}
        self.assertEqual(classes, {"ControllerJourneyUITests", "IPadTouchJourneyUITests", "TouchJourneyUITests"})
        for name in classes:
            self.assertIn(f'<Test Identifier = "{name}">', scheme)


if __name__ == "__main__":
    unittest.main()
