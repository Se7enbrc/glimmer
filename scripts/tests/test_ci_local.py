# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Local/hosted partitions remain exhaustive and release validation fails closed."""

import importlib.util
import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

from fixture_git import FixtureTestCase
from test_release_checks import CHECKS, SHA

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"scripts/{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RUNNER = load("ci-local")
RESULTS = load("ci-test-results")


class CILocalTests(FixtureTestCase):
    def test_core_and_render_cover_all_unit_and_ui_suites_without_overlap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "iOS/GlimmerTests"
            source.mkdir(parents=True)
            (source / "Snapshot.swift").write_text("struct NativeUIRenderTests {}\nclass CompactLauncherRenderTests {}\nstruct UnitTests {}")
            core, render = RUNNER.filters("core", root), RUNNER.filters("render", root)
            self.assertEqual(core[0], "-only-testing:GlimmerTests")
            self.assertEqual(render[-1], "-only-testing:GlimmerUITests")
            excluded = {name.replace("-skip-testing:", "") for name in core[1:]}
            included = {name.replace("-only-testing:", "") for name in render[:-1]}
            self.assertEqual(excluded, included)
            self.assertEqual(len(excluded), 2)

    def test_empty_render_discovery_fails_instead_of_skipping_tests(self):
        with tempfile.TemporaryDirectory() as directory, self.assertRaisesRegex(ValueError, "No render suites"):
            RUNNER.filters("render", Path(directory))

    def test_wrong_xcode_fails_before_building(self):
        with patch.dict(os.environ, DEVELOPER_DIR="/fixture/Xcode"), patch.object(RUNNER, "output", return_value="Xcode 27.1\nBuild version x"):
            with self.assertRaisesRegex(ValueError, "Expected Xcode 26.6"):
                RUNNER.toolchain()

    def test_simulator_timeout_is_explicit_and_never_switches_xcode(self):
        with patch.object(RUNNER, "output", side_effect=["26.5", subprocess.TimeoutExpired("simctl", 20)]):
            with self.assertRaisesRegex(ValueError, "no toolchain was substituted"):
                with RUNNER.simulator():
                    self.fail("must not boot a fallback simulator")

    def test_fresh_simulator_is_deleted_after_test_failure(self):
        runtimes = '{"runtimes":[{"isAvailable":true,"platform":"iOS","version":"26.5","identifier":"ios-26-5"}]}'
        with patch.object(RUNNER, "output", side_effect=["26.5", runtimes, "fixture-udid"]), patch.object(RUNNER.subprocess, "run") as command:
            with self.assertRaisesRegex(ValueError, "test failed"):
                with RUNNER.simulator() as destination:
                    self.assertEqual(destination, "platform=iOS Simulator,id=fixture-udid")
                    raise ValueError("test failed")
            operations = [call.args[0][-2:] for call in command.call_args_list]
            self.assertIn(["shutdown", "fixture-udid"], operations)
            self.assertIn(["delete", "fixture-udid"], operations)

    def test_process_exit_and_compiler_warning_both_fail_the_shard(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            log = Path(directory) / "test.log"
            with patch.object(RUNNER, "ROOT", Path(directory)):
                self.assertEqual(RUNNER.run([sys.executable, "-c", "print('failure detail'); raise SystemExit(65)"], log), 65)
                self.assertIn("failure detail", log.read_text())
                self.assertEqual(RUNNER.run([sys.executable, "-c", "print('file.swift: warning: suspicious')"], log), 1)

    def test_empty_skipped_or_failed_journeys_cannot_pass_validation(self):
        RUNNER.validate_journey_result({"passedTests": 10, "failedTests": 0, "skippedTests": 0})
        for summary in ({}, {"passedTests": 0}, {"passedTests": 1, "skippedTests": 9},
                        {"passedTests": 9, "failedTests": 1}, {"passedTests": 10, "expectedFailures": 1}):
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                RUNNER.validate_journey_result(summary)

    def test_candidate_needs_successful_tier_two_on_exact_sha(self):
        required = CHECKS.REQUIRED[".github/workflows/verify.yml"]
        self.assertEqual(required, {"macOS", "Tier 2"})
        core = {"name": "macOS", "head_sha": SHA, "status": "completed", "conclusion": "success"}
        full = {**core, "name": "Tier 2"}
        CHECKS.validate_jobs([core, full], required, SHA)
        for changed in (None, {"status": "queued"}, {"conclusion": "failure"}, {"conclusion": "skipped"}, {"head_sha": "b" * 40}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                CHECKS.validate_jobs([core] if changed is None else [core, {**full, **changed}], required, SHA)

    def test_extended_work_waits_for_core_and_has_no_mac_matrix(self):
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        self.assertNotIn("matrix:", workflow)
        self.assertIn("needs: [changes, gate]", workflow)
        self.assertIn("if: github.event_name != 'pull_request'", " ".join(workflow.split()))
        for command in ("scripts/ci-local.py core", "scripts/ci-local.py render", "scripts/ci-local.py journeys", "make test-asan"):
            self.assertIn(command, workflow)
        self.assertIn("branches: [main, feat/2026.10.8]", workflow)


class CIResultsTests(FixtureTestCase):
    def test_failure_names_messages_and_source_locations_survive_nested_receipts(self):
        issue = {"testCaseName": {"_value": "Rotation.test"}, "message": {"_value": "timed out"},
                 "documentLocationInCreatingWorkspace": {"url": {"_value": "file:///Tests.swift#StartingLineNumber=42"}}}
        self.assertEqual(RESULTS.failures({"issues": {"_values": [issue, issue]}}),
                         [("Rotation.test", "timed out", "file:///Tests.swift#StartingLineNumber=42")])

    def test_recovered_retry_keeps_first_failure_visible(self):
        log = "Test Case 'Rotation.test' failed (2s).\nTest Case 'Rotation.test' passed (1s)."
        summary = RESULTS.render("render", Path("missing.xcresult"), log, 0)
        self.assertIn("Recovered on an in-job retry", summary)
        self.assertIn("Rotation.test", summary)
        self.assertIn("make ci-local SHARD=render", summary)
        self.assertNotIn("Recovered", RESULTS.render("render", Path("missing"), log.splitlines()[0], 65))

    def test_startup_error_with_no_result_is_actionable(self):
        self.assertIn("startup errors", RESULTS.render("core", Path("missing"), "", 65))
