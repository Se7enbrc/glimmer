# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Only numeric version metadata may bypass PR compilation, never arbitrary xcconfig edits."""

import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "verify-changed.py"
SPEC = importlib.util.spec_from_file_location("verify_changed", SCRIPT)
CHANGED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHANGED)
BASE = "a" * 40
OLD = "// fixture\nMARKETING_VERSION = 2026.10.8\nCURRENT_PROJECT_VERSION = 20261031\n"
NEW = OLD.replace("20261031", "20261032")


class VerifyVersionOnlyTests(unittest.TestCase):
    def decision(self, old, new, paths=None):
        with patch.object(CHANGED.subprocess, "check_output", side_effect=[old, new]):
            return CHANGED.must_build(paths or ["Glimmer/Version.xcconfig", "CHANGELOG.md"], base=BASE)

    def test_only_numeric_values_can_skip_builds(self):
        self.assertFalse(self.decision(OLD, NEW))
        self.assertFalse(self.decision(OLD, NEW.replace("2026.10.8", "2026.10.9")))
        self.assertTrue(self.decision(OLD, NEW, ["Glimmer/Version.xcconfig", "Glimmer/AppModel.swift"]))

    def test_other_settings_and_malformed_or_duplicate_versions_build(self):
        for new in (NEW + "OTHER_SWIFT_FLAGS = -D ALTERED\n", NEW + "#include other.xcconfig\n",
                    NEW.replace("20261032", "$(OVERRIDE)"), NEW + "CURRENT_PROJECT_VERSION = 1\n",
                    NEW.replace("MARKETING_VERSION", "IGNORED_VERSION"), ""):
            with self.subTest(config=new):
                self.assertTrue(self.decision(OLD, new))

    def test_missing_history_and_invalid_base_build(self):
        for error in (subprocess.CalledProcessError(1, "git"), subprocess.TimeoutExpired("git", 10), OSError()):
            with patch.object(CHANGED.subprocess, "check_output", side_effect=error):
                self.assertTrue(CHANGED.must_build(["Glimmer/Version.xcconfig"], base=BASE))
        for base in (None, "", "main", "-bad"):
            self.assertTrue(CHANGED.must_build(["Glimmer/Version.xcconfig"], base=base))
