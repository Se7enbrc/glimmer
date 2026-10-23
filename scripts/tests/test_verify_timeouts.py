# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Keep test deadlines inside job budgets and preserve evidence after failure."""

from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class VerificationTimeoutTests(unittest.TestCase):
    def job(self, name):
        source = (ROOT / ".github/workflows/verify.yml").read_text()
        return re.split(r"\n  [a-z][a-z-]*:\n", source.split(f"  {name}:\n", 1)[1])[0]

    def step(self, job, name):
        return job.split(f"      - name: {name}\n", 1)[1].split("      - name:", 1)[0]

    def test_test_steps_leave_time_for_failure_uploads(self):
        for job, step in (("verify", "Verify"), ("sequoia", "Run the unit tests on macOS 15"),
                          ("ios", "Test iPhone app against this checkout"),
                          ("engine-ios", "Build and test the source package"),
                          ("fuzz", "Fuzz protocol parsers")):
            with self.subTest(job=job):
                source = self.job(job)
                budget = int(re.search(r"    timeout-minutes: (\d+)", source)[1])
                deadline = re.search(r"        timeout-minutes: (\d+)", self.step(source, step))
                self.assertIsNotNone(deadline)
                self.assertLessEqual(int(deadline[1]), budget - 2)

    def test_mac_evidence_uploads_even_after_timeout(self):
        for job, step, paths in (
            ("verify", "Save Mac results", ("build/logs/", "build/Logs/Test/", "build/coverage/swift/")),
            ("sequoia", "Save macOS 15 results", ("build/logs/", "build/sequoia.xcresult")),
        ):
            with self.subTest(job=job):
                source = self.job(job)
                upload = self.step(source, step)
                self.assertIn("if: always()", upload)
                self.assertIn("uses: actions/upload-artifact@", upload)
                for path in paths:
                    self.assertIn(path, upload)
                self.assertIn("set -o pipefail", source)
                self.assertIn("2>&1 | tee build/logs/", source)
        coverage = self.step(self.job("verify"), "Upload coverage")
        self.assertIn("always()", coverage)

    def test_sequoia_passes_result_bundle_to_xcodebuild(self):
        step = self.step(self.job("sequoia"), "Run the unit tests on macOS 15")
        self.assertIn("TEST_FLAGS='-resultBundlePath build/sequoia.xcresult'", step)
        result = subprocess.run(["make", "-n", "test-run", "TEST_FLAGS=-resultBundlePath fixture.xcresult"],
                                cwd=ROOT, capture_output=True, text=True, timeout=10, check=True)
        command = result.stdout.split("xcodebuild test-without-building", 1)[1].split(";", 1)[0]
        self.assertIn("-resultBundlePath fixture.xcresult", command)
