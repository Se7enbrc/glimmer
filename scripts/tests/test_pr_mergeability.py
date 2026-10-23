# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Exercise the metadata-only conflict diagnostic without contacting GitHub."""

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/pr-mergeability.yml"
SHA = "a" * 40


class PRMergeabilityTests(unittest.TestCase):
    def diagnose(self, metadata, api_status=0):
        shell = textwrap.dedent(WORKFLOW.read_text().split("        run: |\n", 1)[1])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            gh = root / "gh"
            gh.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$CALLS"
if [[ "$*" == *'state=open'* ]]; then
  printf '123\\n'
else
  printf '%s\\n' "$METADATA"
  exit "$API_STATUS"
fi
''')
            gh.chmod(0o755)
            summary, calls = root / "summary", root / "calls"
            env = {**os.environ, "PATH": f"{root}:/usr/bin:/bin", "GH_TOKEN": "fixture",
                   "GITHUB_REPOSITORY": "fixture/repo", "GITHUB_STEP_SUMMARY": str(summary),
                   "METADATA": metadata, "API_STATUS": str(api_status), "CALLS": str(calls)}
            result = subprocess.run(["/bin/bash", "-euo", "pipefail", "-c", shell], env=env,
                                    capture_output=True, text=True, timeout=10)
            requests = calls.read_text().splitlines()
            self.assertTrue(all(line.startswith("api --method GET ") for line in requests))
            self.assertTrue(all("/pulls" in line for line in requests))
            return result.returncode, summary.read_text()

    def test_conflict_without_verification_runs_is_reported(self):
        status, summary = self.diagnose(f"open\t{SHA}\tfalse")
        self.assertNotEqual(status, 0)
        self.assertIn(f"PR #123 ({SHA})", summary)
        self.assertIn("Merge conflict blocks automatic Verify and CodeQL", summary)

    def test_mergeable_head_is_not_reported_as_missing_checks(self):
        status, summary = self.diagnose(f"open\t{SHA}\ttrue")
        self.assertEqual(status, 0)
        self.assertIn("No merge conflicts", summary)

    def test_unknown_or_failed_lookup_cannot_claim_no_conflicts(self):
        for metadata, status in ((f"open\t{SHA}\tnull", 0), ("", 1)):
            with self.subTest(metadata=metadata):
                code, summary = self.diagnose(metadata, status)
                self.assertNotEqual(code, 0)
                self.assertNotIn("No merge conflicts", summary)
                if status == 0:
                    self.assertIn("not computed mergeability", summary)
                    self.assertNotIn("Merge conflict blocks", summary)

    def test_closed_pr_is_ignored_and_current_head_is_reported(self):
        status, summary = self.diagnose(f"closed\t{SHA}\tfalse")
        self.assertEqual(status, 0)
        self.assertNotIn("PR #123", summary)
        new_sha = "b" * 40
        status, summary = self.diagnose(f"open\t{new_sha}\tfalse")
        self.assertNotEqual(status, 0)
        self.assertIn(new_sha, summary)
        self.assertNotIn(SHA, summary)

    def test_workflow_only_reads_metadata_from_main(self):
        source = WORKFLOW.read_text()
        self.assertNotIn("pull_request_target", source)
        self.assertNotIn("checkout", source)
        self.assertNotIn("secrets.", source)
        self.assertNotIn("write", source)
        self.assertIn("if: github.ref == 'refs/heads/main'", source)
        self.assertIn("pull-requests: read", source)
        self.assertIn("schedule:", source)
        self.assertIn("branches: [main]", source)
