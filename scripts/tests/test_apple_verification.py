# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Exercise the required CI gate: no Apple consumer or the macOS 15 run may silently disappear."""

from pathlib import Path
import re
import subprocess
from unittest.mock import patch

from fixture_git import FixtureTestCase
from test_verify_changed import CHANGED, SCRIPT


class AppleVerificationTests(FixtureTestCase):
    def test_gate_tracks_all_jobs_and_rejects_missing_or_extra_results(self):
        workflow = (SCRIPT.parents[1] / ".github/workflows/verify.yml").read_text()
        gate = workflow.split("  gate:\n", 1)[1]
        jobs = set(re.search(r"    needs:\s+\[(.*?)\]", gate)[1].split(", "))
        self.assertEqual(jobs, {"changes", *CHANGED.JOB_TASKS})
        self.assertIn("NEEDS: ${{ toJSON(needs) }}", gate)
        for plan in (["checks"], ["checks", "verify", "ios-core"], sorted(CHANGED.JOB_TASKS)):
            needs = {job: {"result": "success" if job in ["changes", *plan] else "skipped"} for job in jobs}
            CHANGED.require_results(plan, needs)
            for job in jobs:
                for outcome in {"success", "failure", "cancelled", "skipped"} - {needs[job]["result"]}:
                    with self.subTest(job=job, outcome=outcome), self.assertRaises(ValueError):
                        CHANGED.require_results(plan, {**needs, job: {"result": outcome}})
            with self.assertRaises(ValueError):
                CHANGED.require_results(plan, {k: v for k, v in needs.items() if k != "checks"})
            for invalid in ([], ["checks", "unknown"]):
                with self.assertRaises(ValueError):
                    CHANGED.require_results(invalid, needs)

    def test_pull_request_selects_consumers_and_preserves_shared_ios_sources(self):
        cases = {
            "docs/INSTALL.md": {"portable"},
            "iOS/Glimmer/Screen.swift": {"portable", "native", "ios", "device"},
            "iOS/GlimmerTests/ScreenTests.swift": {"portable", "native", "ios"},
            "Glimmer/AWDLHelperManager.swift": {"portable", "native", "mac"},
            "Glimmer/ControllerLayouts/ControllerDiagramAnnotations.swift": {"portable", "native", "mac", "ios", "device"},
            "GlimmerTests/ControllerChordHoldConflictTests.swift": {"portable", "native", "mac", "ios"},
            "fuzz/opus.swift": {"portable", "native", "fuzz"},
        }
        for path, tasks in cases.items():
            with self.subTest(path=path), patch.object(CHANGED, "changed_paths", return_value=[path]):
                self.assertEqual(CHANGED.plan("pull_request", None, "1/merge"), tasks)
        for paths in ([], ["GlimmerEngine/Input/test.swift"], ["mise.lock"], [".github/workflows/verify.yml"]):
            with patch.object(CHANGED, "changed_paths", return_value=paths):
                self.assertEqual(CHANGED.plan("pull_request", None, "1/merge"), CHANGED.FULL | {"portable"})

    def test_main_and_direct_candidate_dispatch_run_every_job(self):
        for event, ref in (("push", "main"), ("workflow_dispatch", "release-candidate")):
            self.assertEqual(CHANGED.plan(event, None, ref), CHANGED.FULL | {"portable", "desktop", "compat"})
        self.assertFalse(CHANGED.plan("push", None, "feature") & {"desktop", "compat"})

    def test_native_routing_preserves_desktop_coverage_and_scopes_runner_proof(self):
        workflows = SCRIPT.parents[1] / ".github/workflows"
        verify = (workflows / "verify.yml").read_text()
        codeql = (workflows / "codeql.yml").read_text()
        for workflow in (verify, codeql):
            self.assertIn("apple_runner: ${{ steps.runner.outputs.label }}", workflow)
            self.assertIn("python3 scripts/verify-changed.py --apple-runner", workflow)
        for name in ("verify", "apple-builds", "ios-core", "mac-core", "sequoia"):
            job = re.split(r"\n  [a-z][a-z-]*:\n", verify.split(f"  {name}:\n")[1])[0]
            if name in {"mac-core", "sequoia"}:
                self.assertIn("runs-on: " + {"mac-core":"macos-26", "sequoia":"macos-15"}[name], job)
            else:
                self.assertIn("runs-on: ${{ needs.changes.outputs.apple_runner }}", job)
                self.assertNotIn("GLIMMER_M4_ADMISSION", job.split("    steps:\n")[0])
                self.assertLess(job.index("--require-proof"), job.index("actions/checkout@"))

    def test_apple_runner_admits_only_reviewed_refs_and_actors(self):
        owner, repo = "Se7enbrc", "Se7enbrc/glimmer"
        env = dict(GITHUB_REPOSITORY=repo, GITHUB_ACTOR=owner, GITHUB_TRIGGERING_ACTOR=owner)
        bot, native, hosted = "glimmer-ugfugl-io-release[bot]", "glimmer-native-m4", "macos-26"
        origin = {"full_name": repo}
        pr = {"number": 7, "base": {"repo": origin, "ref": "main"}, "user": {"login": owner}, "head": {"repo": origin}}
        for kind, ref, actor, trigger, expected in [
            ("push", "heads/main", owner, owner, native), ("schedule", "heads/main", owner, owner, native),
            ("workflow_dispatch", "heads/main", owner, owner, native), ("push", "heads/feature", owner, owner, hosted),
            ("workflow_dispatch", "heads/release-candidate", bot, owner, native),
            ("workflow_dispatch", "heads/release-candidate", bot, bot, native),
            ("workflow_dispatch", "heads/release-candidate", bot, "other", hosted),
            ("pull_request", "pull/7/merge", owner, owner, native), ("pull_request", "pull/7/merge", owner, "other", hosted),
            ("pull_request_target", "heads/main", owner, owner, hosted)
        ]:
            values = dict(env, GITHUB_EVENT_NAME=kind, GITHUB_REF="refs/"+ref, GITHUB_ACTOR=actor, GITHUB_TRIGGERING_ACTOR=trigger)
            self.assertEqual(CHANGED.apple_runner(values, {"pull_request": pr}), expected)
        values = dict(env, GITHUB_EVENT_NAME="pull_request", GITHUB_REF="refs/pull/7/merge")
        for changed in ({"user": {"login": "outside"}}, {"head": {"repo": {"full_name": "outside/glimmer"}}}):
            self.assertEqual(CHANGED.apple_runner(values, {"pull_request": {**pr, **changed}}), hosted)

    def test_exact_merge_diff_includes_old_and_new_paths_and_embedded_newlines(self):
        def git(*args):
            return subprocess.check_output(["git", *args], text=True).strip()
        git("init", "-qb", "main")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.invalid")
        old = Path("Mac\nOld.swift")
        old.write_text("fixture")
        git("add", ".")
        git("commit", "-qm", "base")
        base = git("rev-parse", "HEAD")
        git("switch", "-qc", "topic")
        old.rename("iOS-New.swift")
        git("add", "-A")
        git("commit", "-qm", "move")
        git("switch", "-q", "main")
        git("merge", "--no-ff", "topic", "-m", "merge")
        self.assertEqual(set(CHANGED.changed_paths(base)), {str(old), "iOS-New.swift"})
        self.assertEqual(CHANGED.changed_paths(git("rev-parse", "HEAD")), [])
