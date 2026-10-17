# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Exercise the required CI gate: neither Apple consumer may silently disappear."""

import os
from pathlib import Path
import re
import subprocess
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AppleVerificationTests(unittest.TestCase):
    def gate(self, **overrides):
        source = (ROOT / ".github/workflows/verify.yml").read_text().split("  gate:\n", 1)[1]
        match = re.search(r"        run: \|\n((?:          .*\n|\n)+)", source)
        self.assertIsNotNone(match)
        env = dict(os.environ, DECIDED="success", RESULT="success", BUILD="true",
                   ENGINE="success", IOS="success")
        env.update(overrides)
        return subprocess.run(["/bin/bash", "-euo", "pipefail", "-c", textwrap.dedent(match[1])],
                              env=env, capture_output=True, timeout=10).returncode

    def test_both_apps_must_pass_for_code_changes(self):
        self.assertEqual(self.gate(), 0)
        for name in ("DECIDED", "RESULT", "ENGINE", "IOS"):
            for result in ("failure", "cancelled", "skipped"):
                with self.subTest(job=name, result=result):
                    self.assertNotEqual(self.gate(**{name: result}), 0)

    def test_docs_skip_requires_successful_checks_and_explicit_skipped_builds(self):
        skipped = dict(BUILD="false", ENGINE="skipped", IOS="skipped")
        self.assertEqual(self.gate(**skipped), 0)
        for job in ("ENGINE", "IOS"):
            self.assertNotEqual(self.gate(**{**skipped, job: "failure"}), 0)
        self.assertNotEqual(self.gate(**skipped, RESULT="failure"), 0)
        self.assertNotEqual(self.gate(**skipped, DECIDED="failure"), 0)
        for decision in ("", "unknown"):
            self.assertNotEqual(self.gate(**{**skipped, "BUILD": decision}), 0)


if __name__ == "__main__":
    unittest.main()
