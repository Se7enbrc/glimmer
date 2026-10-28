# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Keep test deadlines inside job budgets and preserve evidence after failure."""

import contextlib
import io
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from fixture_git import FixtureTestCase
from test_ci_local import RUNNER

ROOT = Path(__file__).resolve().parents[2]


class VerificationTimeoutTests(FixtureTestCase):
    def job(self, name):
        source = (ROOT / ".github/workflows/verify.yml").read_text()
        return re.split(r"\n  [a-z][a-z-]*:\n", source.split(f"  {name}:\n", 1)[1])[0]

    def step(self, job, name):
        return job.split(f"      - name: {name}\n", 1)[1].split("      - name:", 1)[0]

    def test_test_steps_leave_time_for_failure_uploads(self):
        for job, step in (("verify", "Build the shared Mac test products"),
                          ("verify", "Check native tooling"), ("verify", "Run Mac tests"),
                          ("sequoia", "Run the unit tests on macOS 15"),
                          ("ios-core", "Build Simulator tests and run core"),
                          ("ios-core", "Build and test the source package"),
                          ("ios-core", "Build engine for device and Simulator"),
                          ("ios-core", "Build production iPhone app without signing"),
                          ("extended", "Render and UI tests"), ("extended", "User journeys"),
                          ("extended", "Address sanitizer and deterministic fuzz tests"),
                          ("fuzz", "Fuzz protocol parsers")):
            with self.subTest(job=job, step=step):
                source = self.job(job)
                budget = int(re.search(r"    timeout-minutes: (\d+)", source)[1])
                deadline = re.search(r"        timeout-minutes: (\d+)", self.step(source, step))
                self.assertIsNotNone(deadline)
                self.assertLessEqual(int(deadline[1]), budget - 2)

    def test_evidence_uploads_even_after_timeout(self):
        for job, step, paths in (
            ("verify", "Save Mac results", ("build/logs/", "build/Logs/Test/", "build/coverage/swift/")),
            ("sequoia", "Save macOS 15 results", ("build/logs/", "build/sequoia.xcresult")),
            ("ios-core", "Save core results", ("iOS/build/ci/core/",)),
            ("extended", "Save extended results", ("iOS/build/ci/render/", "build/logs/", "build/Logs/Test/")),
            ("fuzz", "Save fuzzer results", ("build/logs/", "build/fuzz/")),
        ):
            with self.subTest(job=job):
                source = self.job(job)
                upload = self.step(source, step)
                self.assertIn("if: always()", upload)
                self.assertIn("uses: actions/upload-artifact@", upload)
                for path in paths:
                    self.assertIn(path, upload)
        for name in ("Upload script coverage", "Upload Swift coverage"):
            self.assertIn("always()", self.step(self.job("verify"), name))

    def test_each_executor_retains_output_and_failure_status(self):
        for job, step, path in (
            ("ios-core", "Build and test the source package", "build/logs/package-test.log"),
            ("ios-core", "Build production iPhone app without signing", "iOS/build/logs/device.log"),
            ("extended", "Address sanitizer and deterministic fuzz tests", "build/logs/asan.log"),
            ("sequoia", "Run the unit tests on macOS 15", "build/logs/sequoia.log"),
            ("fuzz", "Fuzz protocol parsers", "build/logs/fuzz.log"),
        ):
            with self.subTest(job=job, step=step):
                source = self.step(self.job(job), step)
                self.assertIn("set -o pipefail", source)
                self.assertIn(f"2>&1 | tee {path}", source)
        for job, step, command in (
            ("verify", "Build the shared Mac test products", "mac --build-only"),
            ("verify", "Run Mac tests", "mac --run-only"),
            ("ios-core", "Build Simulator tests and run core", "core"),
            ("extended", "Render and UI tests", "render --run-only"),
            ("extended", "User journeys", "journeys"),
        ):
            self.assertIn(f"python3 scripts/ci-local.py {command}", self.step(self.job(job), step))

    def test_shared_runner_preserves_both_streams_and_timeout_evidence(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()) as console:
            root = Path(directory)
            log = root / "fixture.log"
            with patch.object(RUNNER, "ROOT", root):
                command = [sys.executable, "-u", "-c",
                           "import sys; print('stdout evidence'); print('stderr evidence', file=sys.stderr); sys.exit(65)"]
                self.assertEqual(RUNNER.run(command, log, timeout=5), 65)
                for evidence in ("stdout evidence", "stderr evidence"):
                    self.assertIn(evidence, log.read_text())
                    self.assertIn(evidence, console.getvalue())
                command = [sys.executable, "-u", "-c", "import time; print('before timeout'); time.sleep(30)"]
                self.assertEqual(RUNNER.run(command, log, timeout=1), 124)
                self.assertIn("before timeout", log.read_text())
                self.assertIn("process group terminated", log.read_text())

    def test_sequoia_passes_result_bundle_to_xcodebuild(self):
        step = self.step(self.job("sequoia"), "Run the unit tests on macOS 15")
        self.assertIn("TEST_FLAGS='-resultBundlePath build/sequoia.xcresult'", step)
        result = subprocess.run(["make", "-n", "test-run", "TEST_FLAGS=-resultBundlePath fixture.xcresult"],
                                cwd=ROOT, capture_output=True, text=True, timeout=10, check=True)
        command = result.stdout.split("xcodebuild test-without-building", 1)[1].split(";", 1)[0]
        self.assertIn("-resultBundlePath fixture.xcresult", command)
