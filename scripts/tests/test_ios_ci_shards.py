# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Core and acceptance partition Simulator coverage without rerunning acceptance on pushes."""

from pathlib import Path
import json
import os
import subprocess
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from fixture_git import FixtureTestCase
from test_ci_local import RUNNER

ROOT = Path(__file__).resolve().parents[2]


class IOSCIShardTests(FixtureTestCase):
    def test_shards_are_exact_complements_with_acceptance_off_the_push_gate(self):
        suites = ["NativeUIRenderTests", "ControllerMouseRenderTests", "ControllerLayoutRenderTests",
                  "ControllerShortcutRenderTests"]
        with patch.object(RUNNER, "render_suites", return_value=suites):
            core, render = RUNNER.filters("core"), RUNNER.filters("render")
        self.assertEqual(core[0], "-only-testing:GlimmerTests")
        self.assertEqual(render[-1], "-only-testing:GlimmerUITests")
        excluded = {flag.removeprefix("-skip-testing:") for flag in core[1:]}
        included = {flag.removeprefix("-only-testing:") for flag in render[:-1]}
        self.assertEqual(excluded, included)
        self.assertEqual(included, {f"GlimmerTests/{suite}" for suite in suites})
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        core_job = workflow.split("  ios-core:\n", 1)[1].split("  extended:\n", 1)[0]
        acceptance = workflow.split("  extended:\n", 1)[1].split("  sequoia:\n", 1)[0]
        self.assertIn("python3 scripts/ci-local.py core", core_job)
        self.assertNotIn("ios-tests.tgz", core_job)
        self.assertIn("inputs.mode == 'acceptance'", acceptance)
        self.assertIn("github.event_name == 'workflow_dispatch'", acceptance)
        self.assertIn("needs: changes", acceptance)
        self.assertIn("python3 scripts/ci-local.py acceptance", acceptance)
        self.assertIn("name: acceptance-ledger", acceptance)
        self.assertIn("run-id: ${{ inputs.resume_run }}", acceptance)
        self.assertNotIn("  tier2:", workflow)
        self.assertNotIn("  schedule:", workflow)
        self.assertIn("IOS_CORE: ${{ needs.ios-core.result }}", workflow)
        self.assertIn('test "$IOS_CORE" = "$expected"', workflow)
        self.assertIn("name: ios-core-results", core_job)
        self.assertIn("iOS/build/ci/render/", acceptance)

    def test_build_overlaps_owned_simulator_boot_and_preserves_failures(self):
        root = Path.cwd()
        (root / "iOS").mkdir()
        (root / "iOS/Makefile").touch()
        products = root / "iOS/build/ci/DerivedData/Build/Products"
        products.mkdir(parents=True)
        manifest = products / "Glimmer-iOS_test.xctestrun"
        runtime = '{"runtimes":[{"isAvailable":true,"platform":"iOS","version":"26.5","identifier":"ios"}]}'
        for build_only, run_only, failure, expected in (
            (False, False, 0, ["boot", "test-build", "bootstatus", "test-run", "shutdown", "delete"]),
            (False, False, 65, ["boot", "test-build", "shutdown", "delete"]),
            (True, False, 0, ["test-build"]),
            (False, True, 0, ["boot", "bootstatus", "test-run", "shutdown", "delete"]),
        ):
            events = []
            manifest.touch()
            def execute(command, *args, **kwargs):
                if "test-build" in command:
                    events.append("test-build")
                    if not failure:
                        manifest.touch()
                    return failure
                if "test-run" in command:
                    events.append("test-run")
                    return 71
                if command[:2] == ["xcrun", "simctl"]:
                    events.append(command[2])
                return subprocess.CompletedProcess(command, 0)
            args = SimpleNamespace(shard="core", build_only=build_only, run_only=run_only, diagnostic_retry=False)
            with self.subTest(expected=expected), patch.object(RUNNER, "ROOT", root), \
                    patch.object(RUNNER, "filters", return_value=[]), \
                    patch.object(RUNNER, "output", side_effect=["26.5", runtime, "owned"]), \
                    patch.object(RUNNER, "run", side_effect=execute), patch.object(RUNNER.subprocess, "run", side_effect=execute):
                self.assertEqual(RUNNER.ios(args), 0 if build_only else failure or 71)
                self.assertEqual(events, expected)

    def test_test_without_building_retains_scheme_coverage_and_existing_products(self):
        root = Path.cwd()
        derived = root / "isolated test products"
        products = derived / "Build/Products"
        products.mkdir(parents=True)
        (products / "Glimmer-iOS_iphonesimulator26.5-arm64.xctestrun").touch()
        binary = root / "bin"
        binary.mkdir()
        fake = binary / "xcodebuild"
        fake.write_text(f"#!{sys.executable}\nimport json, os, sys\n"
                        "from pathlib import Path\n"
                        "Path(os.environ['XCODE_ARGUMENTS']).write_text(json.dumps(sys.argv[1:]))\n")
        fake.chmod(0o755)
        recorded = root / "arguments.json"
        flags = ("-enableCodeCoverage YES -only-testing:GlimmerTests/NativeUIRenderTests "
                 "-skip-testing:GlimmerTests/NativeUIRenderTests/excluded "
                 "-resultBundlePath 'result with spaces.xcresult'")
        env = {**os.environ, "PATH": f"{binary}:{os.environ['PATH']}", "XCODE_ARGUMENTS": str(recorded)}
        result = subprocess.run(["make", "-C", "iOS", "test-run", f"DERIVED={derived}",
                                 "TEST_DESTINATION=platform=iOS Simulator,id=fixture", f"TEST_FLAGS={flags}"],
                                cwd=ROOT, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads(recorded.read_text())
        for key, value in {"-project": "Glimmer.xcodeproj", "-scheme": "Glimmer-iOS",
                           "-configuration": "Debug", "-derivedDataPath": str(derived),
                           "-destination": "platform=iOS Simulator,id=fixture", "-enableCodeCoverage": "YES",
                           "-parallel-testing-enabled": "NO", "-resultBundlePath": "result with spaces.xcresult"}.items():
            self.assertIn(key, arguments)
            self.assertEqual(arguments[arguments.index(key) + 1], value)
        self.assertIn("test-without-building", arguments)
        self.assertIn("-only-testing:GlimmerTests/NativeUIRenderTests", arguments)
        self.assertIn("-skip-testing:GlimmerTests/NativeUIRenderTests/excluded", arguments)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", arguments)
        self.assertFalse({"-xctestrun", "build", "build-for-testing", "test"}.intersection(arguments))

    def test_build_for_testing_has_no_suite_filter(self):
        result = subprocess.run(["make", "-n", "-C", "iOS", "test-build",
                                 "TEST_FLAGS=-enableCodeCoverage YES"],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("build-for-testing", result.stdout)
        self.assertIn("-enableCodeCoverage YES", result.stdout)
        self.assertNotIn("-only-testing", result.stdout)
        self.assertNotIn("-skip-testing", result.stdout)
