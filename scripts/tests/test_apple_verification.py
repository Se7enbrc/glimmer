# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Exercise the required CI gate: no Apple consumer or the macOS 15 run may silently disappear."""

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
                   IOS_BUILD="success", IOS="success", SEQUOIA="success", FUZZ="success",
                   APPLE="true", CHECKS="success")
        env.update(overrides)
        return subprocess.run(["/bin/bash", "-euo", "pipefail", "-c", textwrap.dedent(match[1])],
                              env=env, capture_output=True, timeout=10).returncode

    def test_gate_depends_on_every_required_job(self):
        source = (ROOT / ".github/workflows/verify.yml").read_text()
        jobs = set(re.findall(r"^  ([a-z-]+):$", source.split("jobs:\n", 1)[1], re.MULTILINE)) - {"gate"}
        gate = source.split("  gate:\n", 1)[1]
        needs = re.search(r"    needs: \[(.*?)\]", gate)[1]
        self.assertEqual(set(needs.split(", ")), jobs)
        for job, variable in (("fuzz", "FUZZ"), ("sequoia", "SEQUOIA")):
            self.assertIn(f"{variable}: ${{{{ needs.{job}.result }}}}", gate)

    def test_both_apps_must_pass_for_code_changes(self):
        self.assertEqual(self.gate(), 0)
        for name in ("DECIDED", "RESULT", "CHECKS", "IOS_BUILD", "IOS", "SEQUOIA", "FUZZ"):
            for result in ("failure", "cancelled", "skipped"):
                with self.subTest(job=name, result=result):
                    self.assertNotEqual(self.gate(**{name: result}), 0)

    def test_docs_skip_requires_successful_checks_and_explicit_skipped_builds(self):
        skipped = dict(BUILD="false", IOS_BUILD="skipped", IOS="skipped", SEQUOIA="skipped",
                       FUZZ="skipped")
        self.assertEqual(self.gate(**skipped), 0)
        for job in ("IOS_BUILD", "IOS", "SEQUOIA", "FUZZ"):
            self.assertNotEqual(self.gate(**{**skipped, job: "failure"}), 0)
        self.assertNotEqual(self.gate(**skipped, RESULT="failure"), 0)
        self.assertNotEqual(self.gate(**skipped, DECIDED="failure"), 0)
        for decision in ("", "unknown"):
            self.assertNotEqual(self.gate(**{**skipped, "BUILD": decision}), 0)

    def test_mac_only_layout_requires_explicit_skips_and_fuzz(self):
        absent = dict(APPLE="false", IOS_BUILD="skipped", IOS="skipped", SEQUOIA="skipped")
        self.assertEqual(self.gate(**absent), 0)
        self.assertNotEqual(self.gate(**absent, FUZZ="skipped"), 0)
        self.assertNotEqual(self.gate(**{**absent, "APPLE": "unknown"}), 0)


if __name__ == "__main__":
    unittest.main()
