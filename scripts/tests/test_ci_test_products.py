# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Keep the shared Mac test build instrumented and both operating systems gated."""

from pathlib import Path
import subprocess
import unittest

from fixture_git import FixtureTestCase

ROOT = Path(__file__).resolve().parents[2]


class CITestProductsTests(FixtureTestCase):
    def command(self, target):
        return subprocess.run(["make", "-n", target, "COVERAGE=1"], cwd=ROOT,
                              capture_output=True, text=True, check=True).stdout

    def test_shared_build_enables_coverage_before_compilation(self):
        output = self.command("test-build")
        self.assertIn("build-for-testing", output)
        self.assertIn("-enableCodeCoverage YES", output)
        self.assertIn("Testing.framework", output)
        self.assertIn("lib_TestingInterop.dylib", output)

    def test_run_uses_products_and_retains_coverage_failure(self):
        output = self.command("test-run")
        self.assertIn("test-without-building", output)
        self.assertNotIn("build-for-testing", output)
        self.assertIn("-derivedDataPath", output)
        self.assertIn("-resultBundlePath", output)
        self.assertIn("coverage-report.py swift || status=$?", output)
        self.assertIn("exit $status", output)

    def test_only_one_ci_mac_test_compilation(self):
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        self.assertNotIn("  sequoia-build:\n", workflow)
        self.assertEqual(workflow.count("make test-build COVERAGE=1"), 1)
        self.assertIn('"target":"test-run"', workflow)
        self.assertIn("needs: [changes, verify]", workflow)
        self.assertIn("name: sequoia-tests", workflow)
        self.assertIn("runs-on: macos-15", workflow)

    def test_consolidated_checks_keep_all_apple_builds(self):
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        self.assertNotIn("  engine-ios:\n", workflow)
        self.assertNotIn("platform: [Simulator, device]", workflow)
        for command in ("swift build -Xswiftc -warnings-as-errors", "swift test -Xswiftc -warnings-as-errors",
                        "generic/platform=iOS Simulator", "generic/platform=iOS", "make ios-device"):
            self.assertIn(command, workflow)
        self.assertIn("matrix.part == 'checks' && needs.changes.outputs.build == 'true'", workflow)
