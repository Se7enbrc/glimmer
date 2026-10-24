# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "verify-changed.py"
SPEC = importlib.util.spec_from_file_location("verify_changed", SCRIPT)
CHANGED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHANGED)


class VerifyScopeTests(unittest.TestCase):
    def test_documentation_and_the_site_skip_the_build(self):
        self.assertFalse(CHANGED.must_build([
            "README.md", "CHANGELOG.md", "docs/INSTALL.md", "docs/gitbook-docs.yaml",
            "docs/assets/launcher.png", "website/site.css", "index.html",
            ".github/ISSUE_TEMPLATE/bug.yml", ".github/SUPPORT.md", "LICENSE"]))

    def test_any_code_build_or_workflow_change_builds(self):
        for path in ("Glimmer/AppModel.swift", "GlimmerTests/FramePacerTests.swift", "helper/main.swift",
                     "Glimmer.xcodeproj/project.pbxproj", "Glimmer/Version.xcconfig", "Makefile",
                     "scripts/release-checks.py", "scripts/verify-changed.py", "fuzz/rtsp.swift",
                     ".github/workflows/verify.yml", ".pre-commit-config.yaml", "renovate.json"):
            with self.subTest(path=path):
                self.assertTrue(CHANGED.must_build([path, "docs/README.md"]))

    def test_ios_and_shared_package_changes_run_both_apps(self):
        for path in ("iOS/Glimmer/IOSAppModel.swift", "iOS/Glimmer.xcodeproj/project.pbxproj",
                     "iOS/Glimmer.xcodeproj/xcshareddata/xcschemes/Glimmer-iOS.xcscheme",
                     "iOS/Makefile", "Package.swift", "scripts/apple-apps.mk"):
            with self.subTest(path=path):
                self.assertTrue(CHANGED.must_build([path]))

    def test_an_empty_or_blank_list_builds(self):
        self.assertTrue(CHANGED.must_build([]))
        self.assertTrue(CHANGED.must_build(["", "  \n"]))

    def test_the_command_line_prints_an_explicit_successful_decision(self):
        for paths, decision in (("docs/README.md\n", "skip"), ("Glimmer/AppModel.swift\n", "run"), ("", "run")):
            with self.subTest(paths=paths):
                result = subprocess.run([sys.executable, str(SCRIPT)], input=paths, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, decision + "\n")


if __name__ == "__main__":
    unittest.main()
