# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Only pull-request verification may supersede another run."""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class VerificationConcurrencyTests(unittest.TestCase):
    def test_only_pr_runs_can_cancel_and_non_pr_runs_have_unique_groups(self):
        for name in ("verify", "codeql"):
            with self.subTest(workflow=name):
                source = (ROOT / f".github/workflows/{name}.yml").read_text()
                group = source.split("concurrency:\n", 1)[1].split("jobs:", 1)[0]
                group = " ".join(group.split())
                self.assertIn("${{ github.workflow }}", group)
                self.assertIn("${{ github.event.pull_request.number || github.ref }}", group)
                self.assertIn("github.event_name == 'pull_request' && 'pr' || github.run_id", group)
                self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", group)

    def test_closed_pr_replaces_work_without_checking_out_or_building(self):
        for name, entry in (("verify", "changes"), ("codeql", "changes")):
            with self.subTest(workflow=name):
                source = (ROOT / f".github/workflows/{name}.yml").read_text()
                events = source.split("  pull_request:\n", 1)[1].split("\n  ", 1)[0]
                self.assertIn("types: [opened, synchronize, reopened, closed]", events)
                job = source.split(f"  {entry}:\n", 1)[1].split("    steps:", 1)[0]
                self.assertIn("if: github.event.action != 'closed'", job)
                self.assertNotIn("pull_request_target:", source)
        gate = (ROOT / ".github/workflows/verify.yml").read_text().split("  gate:\n", 1)[1]
        self.assertRegex(gate, re.escape("if: always() && github.event.action != 'closed'"))
        analysis = (ROOT / ".github/workflows/codeql.yml").read_text().split("  analyze:\n", 1)[1]
        self.assertRegex(analysis, re.escape("if: always() && github.event.action != 'closed'"))
