# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""The two Simulator shards must cover every test while sharing one compilation."""

from pathlib import Path
import subprocess
import unittest

from fixture_git import FixtureTestCase

ROOT = Path(__file__).resolve().parents[2]


class IOSCIShardTests(FixtureTestCase):
    def test_shards_are_exact_complements_and_both_required(self):
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        self.assertIn("shard: [core, render]", workflow)
        self.assertIn('filter="-only-testing:GlimmerTests/NativeUIRenderTests"', workflow)
        self.assertIn('filter="-skip-testing:GlimmerTests/NativeUIRenderTests"', workflow)
        self.assertIn("needs: [changes, ios-build]", workflow)
        self.assertIn("IOS_BUILD: ${{ needs.ios-build.result }}", workflow)
        self.assertIn('test "$IOS_BUILD" = success', workflow)
        self.assertIn('test "$IOS_BUILD" = skipped', workflow)
        self.assertIn("name: ios-${{ matrix.shard }}-results", workflow)

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
