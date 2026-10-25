# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Exercise the pre-credential guard without minting tokens or changing repository state."""

from pathlib import Path
import os
import sys
import tempfile
import textwrap
import unittest

from fixture_git import FixtureTestCase

from fixture_process import run_fixture

WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/release-candidate.yml"


class RCCutWorkflowTests(FixtureTestCase):
    def guard(self, **overrides):
        source = WORKFLOW.read_text()
        step = source.split("- name: Require main tooling before credentials\n", 1)[1]
        shell = textwrap.dedent(step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0])
        env = {"GITHUB_REPOSITORY": "Se7enbrc/glimmer", "GITHUB_REF": "refs/heads/main",
               "DEFAULT_BRANCH": "main", "TRIGGER_REPOSITORY": "Se7enbrc/glimmer",
               "GITHUB_EVENT_NAME": "workflow_run",
               "GITHUB_WORKFLOW_REF": "Se7enbrc/glimmer/.github/workflows/release-candidate.yml@refs/heads/main"}
        env.update(overrides)
        return run_fixture(["/bin/bash", "-euo", "pipefail", "-c", shell], env=env).returncode

    def test_both_main_tooling_triggers_pass(self):
        for event in ("pull_request_target", "workflow_run"):
            self.assertEqual(self.guard(GITHUB_EVENT_NAME=event), 0)

    def test_missing_or_untrusted_context_stops_before_token(self):
        for key, value in (("GITHUB_REF", "refs/heads/feature"), ("DEFAULT_BRANCH", "feature"),
                           ("GITHUB_WORKFLOW_REF",
                            "Se7enbrc/glimmer/.github/workflows/release-candidate.yml@refs/heads/pr"),
                           ("GITHUB_REPOSITORY", "fork/glimmer"), ("TRIGGER_REPOSITORY", "fork/glimmer"),
                           ("TRIGGER_REPOSITORY", ""), ("GITHUB_EVENT_NAME", "workflow_dispatch"),
                           ("GITHUB_WORKFLOW_REF", "")):
            with self.subTest(key=key, value=value):
                self.assertNotEqual(self.guard(**{key: value}), 0)

    def test_guard_precedes_token_and_checkouts_pin_main_event_sha(self):
        source = WORKFLOW.read_text()
        self.assertLess(source.index("- name: Require main tooling"),
                        source.index("- name: Mint a scoped release token"))
        self.assertEqual(source.count("ref: ${{ github.sha }}"), 2)
        self.assertIn("github.ref == 'refs/heads/main'", source.split("  cut:", 1)[1])
        self.assertIn("environment: rc-cut", source)

    def test_candidate_scans_have_separate_concurrency_and_complete_processing(self):
        for name in ('verify.yml', 'codeql.yml'):
            source = (WORKFLOW.parent / name).read_text()
            concurrency = source.split('\nconcurrency:\n', 1)[1].split('\njobs:', 1)[0]
            self.assertIn('github.ref', concurrency)
            self.assertIn('github.run_id', concurrency)
            self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", concurrency)
        self.assertIn('wait-for-processing: true', (WORKFLOW.parent / 'codeql.yml').read_text())
        self.assertIn('timeout-minutes: 55', WORKFLOW.read_text())

    def test_workflow_run_head_is_a_candidate_only_when_the_pr_targets_main(self):
        source = WORKFLOW.read_text()
        start = source.index("          ready=false")
        shell = textwrap.dedent(source[start:source.index("\n  cut:", start)])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            (root / "scripts/release-checks.py").write_text("raise SystemExit(0)\n")
            (root / "python3").symlink_to(sys.executable)
            gh = root / "gh"
            gh.write_text('#!/bin/bash\nprintf "%s\\n" "$FIXTURE_PR"\n')
            gh.chmod(0o755)
            for base, expected in (("main", "true"), ("feature", "false"), ("", "false")):
                with self.subTest(base=base):
                    output = root / "output"
                    output.write_text("")
                    env = {**os.environ, "PATH": f"{root}:/usr/bin:/bin", "PR_NUMBER": "1", "HEAD_SHA": "a" * 40,
                           "GITHUB_REPOSITORY": "Se7enbrc/glimmer", "GITHUB_OUTPUT": str(output),
                           "FIXTURE_PR": f"{'a' * 40} OPEN true {base}"}
                    result = run_fixture(["/bin/bash", "-euo", "pipefail", "-c", shell], env=env,
                                         cwd=root)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f"ready={expected}\n", output.read_text())
