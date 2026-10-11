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

    def test_an_empty_or_blank_list_builds(self):
        self.assertTrue(CHANGED.must_build([]))
        self.assertTrue(CHANGED.must_build(["", "  \n"]))

    def test_the_command_line_exit_code_carries_the_decision(self):
        def run(text):
            return subprocess.run([sys.executable, str(SCRIPT)], input=text, text=True).returncode
        self.assertEqual(run("docs/README.md\n"), 1)
        self.assertEqual(run("Glimmer/AppModel.swift\n"), 0)


if __name__ == "__main__":
    unittest.main()
