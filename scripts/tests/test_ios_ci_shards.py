# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""The two Simulator shards must cover every test while sharing one compilation."""

from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

from fixture_git import FixtureTestCase
from test_ci_local import RUNNER

ROOT = Path(__file__).resolve().parents[2]


class IOSCIShardTests(FixtureTestCase):
    def test_shards_are_exact_complements_and_both_required(self):
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
        render_job = workflow.split("  extended:\n", 1)[1].split("  tier2:\n", 1)[0]
        self.assertIn("python3 scripts/ci-local.py core", core_job)
        self.assertIn('tar -C iOS/build/ci/DerivedData/Build -czf "$RUNNER_TEMP/ios-tests.tgz" Products', core_job)
        self.assertIn("name: ios-tests", core_job)
        self.assertIn("needs: [changes, gate]", render_job)
        self.assertIn("name: ios-tests", render_job)
        self.assertIn('tar -C iOS/build/ci/DerivedData/Build -xzf "$RUNNER_TEMP/ios-tests.tgz"', render_job)
        self.assertIn("python3 scripts/ci-local.py render --run-only", render_job)
        self.assertNotIn("test-build", render_job)
        self.assertIn("IOS_CORE: ${{ needs.ios-core.result }}", workflow)
        self.assertIn('test "$IOS_CORE" = success', workflow)
        self.assertIn('test "$IOS_CORE" = skipped', workflow)
        tier2 = workflow.split("  tier2:\n", 1)[1].split("  sequoia:\n", 1)[0]
        self.assertIn("needs: [gate, extended]", tier2)
        self.assertIn('test "$CORE" = success', tier2)
        self.assertIn('test "$EXTENDED" = success', tier2)
        self.assertIn("name: ios-core-results", core_job)
        self.assertIn("iOS/build/ci/render/", render_job)

    def test_test_without_building_uses_only_downloaded_products(self):
        result = subprocess.run(["make", "-n", "-C", "iOS", "test-run",
                                 "TEST_FLAGS=-only-testing:GlimmerTests/NativeUIRenderTests"],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("test-without-building -xctestrun", result.stdout)
        self.assertNotIn("-project", result.stdout)
        self.assertIn("-parallel-testing-enabled NO", result.stdout)
        self.assertIn("-only-testing:GlimmerTests/NativeUIRenderTests", result.stdout)

    def test_build_for_testing_has_no_suite_filter(self):
        result = subprocess.run(["make", "-n", "-C", "iOS", "test-build",
                                 "TEST_FLAGS=-enableCodeCoverage YES"],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("build-for-testing", result.stdout)
        self.assertIn("-enableCodeCoverage YES", result.stdout)
        self.assertNotIn("-only-testing", result.stdout)
        self.assertNotIn("-skip-testing", result.stdout)
