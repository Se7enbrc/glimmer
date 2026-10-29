# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Verify isolation and silence without launching the Mac test host."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
name = Path(sys.argv[0]).name
with open(os.environ["JOURNEY_TEST_LOG"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps([name, *sys.argv[1:]]) + "\\n")
if name == "osascript":
    print(os.environ.get("JOURNEY_TEST_VOICEOVER", "false"))
if name == "date":
    print("1793190000" if "+%s" in sys.argv else "2026-10-28T12:00:00Z")
if name == "xcodebuild" and "build-for-testing" in sys.argv:
    if not Path("Glimmer/BuildInfo.generated.swift").is_file():
        sys.exit("Missing generated build information in a fresh checkout")
if name == "xcodebuild" and "test-without-building" in sys.argv:
    if os.environ.get("JOURNEY_TEST_FAIL"):
        sys.exit(65)
'''


class MacControllerJourneyTests(unittest.TestCase):
    def run_journeys(self, *, speech="false", fail=False, appearance="all", selection="", skip_build=False):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / "source"
            (source / "scripts").mkdir(parents=True)
            (source / "Glimmer").mkdir()
            for name in ["mac-controller-journeys.sh", "check-journey-silence.py", "generate-build-info.sh"]:
                shutil.copy2(ROOT / "scripts" / name, source / "scripts" / name)
            binaries = directory / "bin"
            binaries.mkdir()
            for name in ["xcodebuild", "xcrun", "osascript", "date"]:
                tool = binaries / name
                tool.write_text(TOOL)
                tool.chmod(0o755)
            log = directory / "calls.jsonl"
            environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                               JOURNEY_TEST_LOG=str(log), JOURNEY_TEST_VOICEOVER=speech,
                               JOURNEY_APPEARANCE=appearance, JOURNEY_TEST_FLAGS=selection,
                               JOURNEY_SKIP_BUILD="1" if skip_build else "0",
                               JOURNEY_DERIVED=str(directory / "build"),
                               JOURNEY_RESULTS=str(directory / "results"))
            environment.pop("JOURNEY_TEST_FAIL", None)
            if fail:
                environment["JOURNEY_TEST_FAIL"] = "1"
            result = subprocess.run(["bash", str(source / "scripts/mac-controller-journeys.sh")],
                                    env=environment, text=True, capture_output=True, check=False)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            return result, calls

    def test_only_isolated_ui_target_adhoc_in_both_appearances(self):
        result, calls = self.run_journeys()
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [call for call in calls if call[0] == "xcodebuild"]
        self.assertEqual(len(builds), 3)
        for build in builds:
            self.assertIn("-only-testing:GlimmerUITests", build)
            self.assertIn("CODE_SIGNING_ALLOWED=YES", build)
            self.assertIn("CODE_SIGN_IDENTITY=-", build)
            self.assertIn("DEVELOPMENT_TEAM=", build)
            self.assertTrue(any(flag.startswith("CODE_SIGN_ENTITLEMENTS=")
                                and flag.endswith("/GlimmerUITests/Journey.entitlements") for flag in build))
            self.assertIn("PRODUCT_BUNDLE_IDENTIFIER=io.ugfugl.Glimmer.JourneyHost", build)
            self.assertIn("Glimmer-Controller-Journeys", build)
        self.assertIn("JOURNEY_APPEARANCE=light", builds[1])
        self.assertIn("JOURNEY_APPEARANCE=dark", builds[2])

    def test_resume_runs_only_selected_test_and_appearance_without_rebuilding(self):
        selected = "-only-testing:GlimmerUITests/MacControllerJourneyUITests/testControllerOnlyLaunch"
        result, calls = self.run_journeys(appearance="dark", selection=selected, skip_build=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [call for call in calls if call[0] == "xcodebuild"]
        self.assertEqual(len(builds), 1)
        self.assertIn("test-without-building", builds[0])
        self.assertIn(selected, builds[0])
        self.assertNotIn("-only-testing:GlimmerUITests", builds[0])
        self.assertIn("JOURNEY_APPEARANCE=dark", builds[0])

    def test_voiceover_or_unknown_state_refuses_before_build(self):
        for speech in ["true", "unknown"]:
            with self.subTest(speech=speech):
                result, calls = self.run_journeys(speech=speech)
                self.assertEqual(result.returncode, 1)
                self.assertFalse(any(call[0] == "xcodebuild" for call in calls))

    def test_failure_still_exports_evidence_and_runs_both_appearances(self):
        result, calls = self.run_journeys(fail=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(sum("test-without-building" in call for call in calls), 2)
        self.assertEqual(sum(call[:3] == ["xcrun", "xcresulttool", "export"] for call in calls), 2)


if __name__ == "__main__":
    unittest.main()
