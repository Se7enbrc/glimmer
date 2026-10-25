# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

from fixture_git import FixtureTestCase

SCRIPT = Path(__file__).resolve().parents[1] / "codeql-swift-changed.py"
SPEC = importlib.util.spec_from_file_location("codeql_swift_changed", SCRIPT)
CHANGED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHANGED)


class SwiftScanScopeTests(FixtureTestCase):
    def test_anything_the_traced_build_reads_needs_the_scan(self):
        for path in ("Glimmer/Stream/VideoDecoder.swift", "helper/main.swift", "LoginHelper/main.swift",
                     "Glimmer.xcodeproj/project.pbxproj",
                     "Glimmer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
                     "Glimmer/StreamLib.xcconfig", "Glimmer/Version.xcconfig", "Glimmer-Bridging-Header.h",
                     "Glimmer/Stream/CHelpers.h", "Makefile", "scripts/generate-build-info.sh",
                     "scripts/release-bundle.mk",
                     "scripts/codeql-swiftc.sh", "scripts/codeql-coverage.py",
                     "scripts/codeql-swift-changed.py", ".github/workflows/codeql.yml"):
            with self.subTest(path=path):
                self.assertTrue(CHANGED.must_scan([path, "docs/README.md"]))

    def test_docs_tooling_tests_and_the_site_skip_it(self):
        self.assertFalse(CHANGED.must_scan([
            "README.md", "docs/RELEASE.md", "CHANGELOG.md", "scripts/release-checks.py",
            "scripts/tests/test_release.py", "GlimmerTests/FramePacerTests.swift", "fuzz/rtsp.swift",
            ".github/workflows/verify.yml", "index.html", "website/site.css", "renovate.json"]))

    def test_an_empty_or_blank_list_scans(self):
        self.assertTrue(CHANGED.must_scan([]))
        self.assertTrue(CHANGED.must_scan(["", "  \n"]))

    def test_the_command_line_prints_an_explicit_successful_decision(self):
        for paths, decision in (("docs/README.md\n", "skip"), ("Glimmer/AppModel.swift\n", "run"), ("", "run")):
            with self.subTest(paths=paths):
                result = subprocess.run([sys.executable, str(SCRIPT)], input=paths, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, decision + "\n")


if __name__ == "__main__":
    unittest.main()
