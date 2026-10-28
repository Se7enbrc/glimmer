# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Cached builds must never bypass compilation, security extraction or credential boundaries."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

from fixture_git import FixtureTestCase

ROOT = Path(__file__).resolve().parents[2]


class CICachePolicyTests(FixtureTestCase):
    def test_key_separates_toolchains_locks_and_instrumentation(self):
        action = (ROOT / ".github/actions/build-cache/action.yml").read_text()
        for field in ("RUNNER_OS", "RUNNER_ARCH", "xcode", "VARIANT", "LOCKS"):
            self.assertIn(field, action)
        self.assertNotIn("$GITHUB_SHA", action)
        self.assertNotIn("build/Build/", action)
        self.assertIn("Package.resolved", action)
        self.assertIn("third_party/**", action)
        self.assertIn("test \"$(xcodebuild -version | sed -n '1p')\" = 'Xcode 26.6'", action)
        for forbidden in ("Keychains", "provisionprofile", ".p12", "signing.env", "ios-unsigned", "build/dist"):
            self.assertNotIn(forbidden, action)

    def test_codeql_never_reuses_compiled_production_sources(self):
        workflow = (ROOT / ".github/workflows/codeql.yml").read_text()
        self.assertNotIn("build-cache", workflow)
        self.assertIn("COMPILATION_CACHE_ENABLE_CACHING = NO", workflow)
        self.assertIn("SWIFT_ENABLE_COMPILE_CACHE = NO", workflow)
        self.assertIn("python3 scripts/codeql-coverage.py", workflow)
        self.assertIn("wait-for-processing: true", workflow)
        self.assertIn("CodeQL upload ${{ steps.analyze.outputs.sarif-id }}", workflow)

    def test_signing_jobs_never_restore_build_caches(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertNotIn("actions/cache", workflow.split("  sign:\n", 1)[1])
        self.assertNotIn("build-cache", workflow.split("  sign:\n", 1)[1])
        delivery = (ROOT / ".github/workflows/ios-testflight.yml").read_text()
        self.assertNotIn("actions/cache", delivery)
        build = (ROOT / ".github/workflows/ios-testflight-build.yml").read_text()
        self.assertNotIn("secrets.", build)
        self.assertLess(build.index("ios-testflight.py build-gate"), build.index("actions/cache"))

    def test_native_and_portable_test_partitions_are_disjoint_and_exhaustive(self):
        spec = importlib.util.spec_from_file_location("script_tests", ROOT / "scripts/test-scripts.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        discovered = {path.stem for path in (ROOT / "scripts/tests").glob("test_*.py")}
        native = discovered & module.NATIVE
        portable = discovered - module.NATIVE
        self.assertFalse(native & portable)
        self.assertEqual(native | portable, discovered)
        self.assertIn("test_update_signature", native)
        self.assertIn("test_candidate_ref_checks", portable)

    def test_full_coverage_combines_both_required_partitions(self):
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        self.assertIn("cp build/coverage/parts/coverage-python-portable/.coverage build/coverage/python/.coverage.portable", workflow)
        self.assertIn("cp build/coverage/parts/coverage-python-macos/.coverage build/coverage/python/.coverage.macos", workflow)
        self.assertIn('test "$CHECKS" = success', workflow)
        self.assertIn('test "$RESULT" = success', workflow)

    def test_missing_boundary_checker_cannot_turn_engine_verification_off(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Package.swift").touch()
            (root / "scripts").mkdir()
            (root / "scripts/test-scripts.py").write_text("raise SystemExit(0)\n")
            (root / "Makefile").write_text(f"include {ROOT}/scripts/ci-checks.mk\n")
            result = subprocess.run(["make", "check-macos"], cwd=root, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
