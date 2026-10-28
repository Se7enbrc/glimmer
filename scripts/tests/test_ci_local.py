# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Local/hosted partitions remain exhaustive and release validation fails closed."""

import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

from fixture_git import FixtureTestCase
from test_release_checks import CHECKS, SHA
from test_release_candidate_cut import REQUIRED as CUT_FIXTURE_CHECKS

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"scripts/{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RUNNER = load("ci-local")
RESULTS = load("ci-test-results")


def project_fixture(paths):
    objects = {
        "project": {"isa": "PBXProject", "mainGroup": "group"},
        "group": {"isa": "PBXGroup", "children": []},
        "target": {"isa": "PBXNativeTarget", "name": "GlimmerTests", "buildPhases": ["phase"]},
        "phase": {"isa": "PBXSourcesBuildPhase", "files": []},
    }
    for index, path in enumerate(paths):
        reference, build = f"file{index}", f"build{index}"
        objects[reference] = {"isa": "PBXFileReference", "path": path, "sourceTree": "SOURCE_ROOT"}
        objects[build] = {"isa": "PBXBuildFile", "fileRef": reference}
        objects["group"]["children"].append(reference)
        objects["phase"]["files"].append(build)
    return {"rootObject": "project", "objects": objects}


class CILocalTests(FixtureTestCase):
    def test_cut_fixture_supplies_every_required_release_check(self):
        self.assertEqual(set(CUT_FIXTURE_CHECKS), set().union(*CHECKS.REQUIRED.values()))

    def test_core_and_render_cover_all_unit_and_ui_suites_without_overlap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "iOS/GlimmerTests"
            source.mkdir(parents=True)
            (source / "Snapshot.swift").write_text("struct NativeUIRenderTests {}\nclass CompactLauncherRenderTests {}\nstruct UnitTests {}")
            shared = root / "GlimmerTests"
            shared.mkdir()
            (shared / "Controller.swift").write_text("struct ControllerMouseRenderTests {}")
            (shared / "MacOnly.swift").write_text("struct MacOnlyRenderTests {}")
            project = project_fixture(["GlimmerTests/Snapshot.swift", "../GlimmerTests/Controller.swift"])
            with patch.object(RUNNER, "output", return_value=json.dumps(project)):
                core, render = RUNNER.filters("core", root), RUNNER.filters("render", root)
            self.assertEqual(core[0], "-only-testing:GlimmerTests")
            self.assertEqual(render[-1], "-only-testing:GlimmerUITests")
            excluded = {name.replace("-skip-testing:", "") for name in core[1:]}
            included = {name.replace("-only-testing:", "") for name in render[:-1]}
            self.assertEqual(excluded, included)
            self.assertEqual(len(excluded), 3)
            self.assertIn("GlimmerTests/ControllerMouseRenderTests", included)
            self.assertNotIn("GlimmerTests/MacOnlyRenderTests", included)

    def test_empty_render_discovery_fails_instead_of_skipping_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "iOS").mkdir()
            (root / "iOS/Units.swift").write_text("struct UnitTests {}")
            with patch.object(RUNNER, "output", return_value=json.dumps(project_fixture(["Units.swift"]))):
                with self.assertRaisesRegex(ValueError, "No render suites"):
                    RUNNER.filters("render", root)

    def test_missing_target_and_unresolved_membership_fail_closed(self):
        for project in (project_fixture([]), {"rootObject": "project", "objects": {}}):
            with self.subTest(project=project), self.assertRaises(ValueError):
                RUNNER.configured_test_sources(project, Path("/fixture/iOS"))
        project = project_fixture(["Tests.swift"])
        project["objects"]["group"]["children"] = []
        with self.assertRaisesRegex(ValueError, "complete configured"):
            RUNNER.configured_test_sources(project, Path("/fixture/iOS"))

    def test_normal_runs_use_one_attempt_and_diagnostic_success_stays_nonqualifying(self):
        self.assertEqual(RUNNER.test_flags(), [])
        self.assertIn("-retry-tests-on-failure", RUNNER.test_flags(True))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(RUNNER.completion_status(0, False), 0)
            self.assertNotEqual(RUNNER.completion_status(0, True), 0)
            self.assertEqual(RUNNER.completion_status(65, True), 65)
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        self.assertNotIn("--diagnostic-retry", workflow)
        self.assertNotIn("-test-iterations", workflow)
        self.assertNotIn("-retry-tests-on-failure", workflow)

    def test_hosted_diagnostic_retry_fails_before_toolchain_or_tests(self):
        with patch.dict(os.environ, GITHUB_ACTIONS="true"), patch.object(sys, "argv", ["ci-local", "core", "--diagnostic-retry"]), \
                patch.object(RUNNER, "toolchain") as toolchain, contextlib.redirect_stderr(io.StringIO()):
            self.assertNotEqual(RUNNER.main(), 0)
            toolchain.assert_not_called()

    def test_receipt_only_validation_does_not_change_the_compatibility_toolchain(self):
        with patch.object(sys, "argv", ["ci-local", "mac", "--validate-result", "sequoia.xcresult"]), \
                patch.object(RUNNER, "toolchain") as toolchain, patch.object(RUNNER, "receipt_status", return_value=1) as validate:
            self.assertEqual(RUNNER.main(), 1)
            toolchain.assert_not_called()
            validate.assert_called_once_with(Path("sequoia.xcresult"), journeys=False)

    def test_manifest_reset_preserves_other_schemes_and_rejects_ambiguous_products(self):
        with tempfile.TemporaryDirectory() as directory:
            derived = Path(directory)
            products = derived / "Build/Products"
            products.mkdir(parents=True)
            for name in ("Glimmer-iOS_old.xctestrun", "Glimmer-iOS_new.xctestrun", "Other_arm64.xctestrun"):
                (products / name).touch()
            with self.assertRaisesRegex(ValueError, "Expected one"):
                RUNNER.manifests(derived, "Glimmer-iOS")
            RUNNER.manifests(derived, "Glimmer-iOS", clear=True)
            self.assertEqual([path.name for path in products.iterdir()], ["Other_arm64.xctestrun"])
            with self.assertRaises(ValueError):
                RUNNER.manifests(derived, "Glimmer-iOS")
            (products / "Glimmer-iOS_arm64.xctestrun").touch()
            RUNNER.manifests(derived, "Glimmer-iOS")

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

    def test_cold_boot_has_headroom_without_changing_command_timeouts(self):
        runtimes = '{"runtimes":[{"isAvailable":true,"platform":"iOS","version":"26.5","identifier":"ios-26-5"}]}'
        with patch.object(RUNNER, "output", side_effect=["26.5", runtimes, "owned-device"]), \
                patch.object(RUNNER.subprocess, "run") as command:
            with RUNNER.simulator():
                pass
        self.assertEqual([call.kwargs["timeout"] for call in command.call_args_list], [60, 300, 30, 30])

    def test_cleanup_errors_preserve_boot_or_test_exception_and_still_delete(self):
        runtimes = '{"runtimes":[{"isAvailable":true,"platform":"iOS","version":"26.5","identifier":"ios-26-5"}]}'
        for phase in ("bootstatus", "test"):
            original = subprocess.TimeoutExpired("bootstatus", 300) if phase == "bootstatus" else ValueError("test failed")
            def execute(command, **options):
                if command[2] == phase:
                    raise original
                if command[2] in {"shutdown", "delete"}:
                    raise subprocess.TimeoutExpired(command, 30)
            with self.subTest(phase=phase), patch.object(RUNNER, "output", side_effect=["26.5", runtimes, "owned-device"]), \
                    patch.object(RUNNER.subprocess, "run", side_effect=execute) as command, \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                with self.assertRaises(type(original)) as raised:
                    with RUNNER.simulator():
                        raise original
                self.assertIs(raised.exception, original)
                self.assertEqual([call.args[0][-2:] for call in command.call_args_list[-2:]],
                                 [["shutdown", "owned-device"], ["delete", "owned-device"]])
                self.assertIn("cleanup", errors.getvalue().lower())

    def test_cleanup_failure_after_success_is_surfaced_and_delete_is_attempted(self):
        runtimes = '{"runtimes":[{"isAvailable":true,"platform":"iOS","version":"26.5","identifier":"ios-26-5"}]}'
        for action in ("shutdown", "delete"):
            failure = subprocess.TimeoutExpired(action, 30)
            def execute(command, **options):
                if command[2] == action:
                    raise failure
            with self.subTest(action=action), patch.object(RUNNER, "output", side_effect=["26.5", runtimes, "owned-device"]), \
                    patch.object(RUNNER.subprocess, "run", side_effect=execute) as command:
                with self.assertRaises(subprocess.TimeoutExpired) as raised:
                    with RUNNER.simulator():
                        pass
                self.assertIs(raised.exception, failure)
                self.assertEqual(command.call_args_list[-1].args[0][-2:], ["delete", "owned-device"])

    def test_process_exit_and_compiler_warning_both_fail_the_shard(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            log = Path(directory) / "test.log"
            with patch.object(RUNNER, "ROOT", Path(directory)):
                self.assertEqual(RUNNER.run([sys.executable, "-c", "print('failure detail'); raise SystemExit(65)"], log), 65)
                self.assertIn("failure detail", log.read_text())
                self.assertEqual(RUNNER.run([sys.executable, "-c", "print('file.swift: warning: suspicious')"], log), 1)

    def test_empty_skipped_or_failed_journeys_cannot_pass_validation(self):
        RUNNER.validate_test_result({"passedTests": 10, "failedTests": 0, "skippedTests": 0})
        for summary in ({}, {"passedTests": 0}, {"passedTests": 1, "skippedTests": 9},
                        {"passedTests": 9, "failedTests": 1}, {"passedTests": 10, "expectedFailures": 1}):
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                RUNNER.validate_test_result(summary, journeys=True)

    def test_empty_and_failed_core_render_or_mac_receipts_cannot_pass(self):
        RUNNER.validate_test_result({"passedTests": 1, "failedTests": 0, "skippedTests": 1})
        for summary in ({}, {"passedTests": 0, "failedTests": 0}, {"passedTests": True, "failedTests": 0},
                        {"passedTests": 10}, {"passedTests": 9, "failedTests": 1}):
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                RUNNER.validate_test_result(summary)

    def test_candidate_needs_successful_core_on_exact_sha_without_acceptance(self):
        required = CHECKS.REQUIRED[".github/workflows/verify.yml"]
        self.assertEqual(required, {"macOS"})
        core = {"name": "macOS", "head_sha": SHA, "status": "completed", "conclusion": "success"}
        CHECKS.validate_jobs([core], required, SHA)
        for changed in (None, {"status": "queued"}, {"conclusion": "failure"}, {"conclusion": "skipped"}, {"head_sha": "b" * 40}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                CHECKS.validate_jobs([] if changed is None else [{**core, **changed}], required, SHA)

    def test_acceptance_is_explicit_and_does_not_repeat_core_or_run_nightly(self):
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        self.assertNotIn("matrix:", workflow)
        self.assertNotIn("schedule:", workflow)
        extended = workflow.split("  extended:\n", 1)[1].split("  sequoia:\n", 1)[0]
        self.assertIn("needs: changes", extended)
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.mode == 'acceptance'", " ".join(extended.split()))
        self.assertIn("scripts/ci-local.py acceptance", extended)
        self.assertIn("name: acceptance-ledger", extended)
        self.assertIn("retention-days: 90", extended)
        self.assertIn("if: always()", extended)
        gate = workflow.split("  gate:\n", 1)[1]
        self.assertIn("name: ${{ inputs.mode == 'acceptance' && 'Acceptance bookkeeping' || 'macOS' }}", " ".join(gate.split()))
        self.assertNotIn("name: ios-tests", workflow)
        for name in ("verify", "ios-core", "fuzz", "checks", "gate"):
            job = workflow.split(f"  {name}:\n", 1)[1].split("    steps:", 1)[0]
            self.assertIn("inputs.mode != 'acceptance'", job)
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
