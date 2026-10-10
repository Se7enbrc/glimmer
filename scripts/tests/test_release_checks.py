"""The candidate gate rejects missing, stale or unsuccessful upstream checks."""

import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("release_checks", Path(__file__).parents[1] / "release-checks.py")
CHECKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKS)
SHA = "a" * 40
MERGE = "b" * 40
WORKFLOW = ".github/workflows/codeql.yml"


def run(**changes):
    return {"id": 1, "workflow_id": 2, "path": WORKFLOW, "head_sha": SHA,
            "head_repository": {"full_name": CHECKS.REPO}, "event": "pull_request",
            "status": "completed", "conclusion": "success", "run_number": 4, "run_attempt": 1,
            "run_started_at": "2026-10-09T20:00:00Z", "pull_requests": [{"number": 114}], **changes}


def analyses(**changes):
    return [{"id": index, "category": category, "analysis_key": f"{WORKFLOW}:analyze",
             "ref": "refs/pull/114/merge", "commit_sha": MERGE, "error": "", "rules_count": 10,
             "created_at": "2026-10-09T20:01:00Z", **changes}
            for index, category in enumerate(sorted(CHECKS.CATEGORIES), 1)]


def language_jobs(**changes):
    return {name: {"name": name, "head_sha": SHA, "status": "completed", "conclusion": "success",
                   "started_at": "2026-10-09T20:00:00Z", **changes}
            for name in CHECKS.REQUIRED[WORKFLOW]}


class RequiredChecksTests(unittest.TestCase):
    def test_latest_run_must_be_green_even_if_older_run_passed(self):
        for conclusion, status in (("failure", "completed"), ("cancelled", "completed"),
                                   (None, "in_progress"), ("skipped", "completed")):
            with self.subTest(conclusion=conclusion), self.assertRaises(ValueError):
                CHECKS.latest_run([run(), run(run_number=5, conclusion=conclusion, status=status)],
                                  WORKFLOW, SHA, 2)
        self.assertEqual(CHECKS.latest_run([run()], WORKFLOW, SHA, 2)["id"], 1)

    def test_spoofed_name_or_wrong_source_cannot_authorize(self):
        for changes in ({"path": ".github/workflows/fake.yml"}, {"workflow_id": 99},
                        {"head_sha": "c" * 40}, {"head_repository": {"full_name": "fork/glimmer"}},
                        {"event": "pull_request_target"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                CHECKS.latest_run([run(**changes)], WORKFLOW, SHA, 2)

    def test_every_required_language_job_must_pass_on_the_exact_commit(self):
        names = CHECKS.REQUIRED[WORKFLOW]
        jobs = [{"name": name, "head_sha": SHA, "status": "completed", "conclusion": "success"}
                for name in names]
        CHECKS.validate_jobs(jobs, names, SHA)
        for bad in (jobs[:-1], jobs + [jobs[0]], [{**job, "conclusion": "skipped"} for job in jobs],
                    [{**job, "head_sha": MERGE} for job in jobs]):
            with self.subTest(jobs=bad), self.assertRaises(ValueError):
                CHECKS.validate_jobs(bad, names, SHA)

    def test_pr_analysis_can_identify_only_its_exact_reviewed_head(self):
        CHECKS.validate_analyses(analyses(), language_jobs(), SHA, "refs/pull/114/merge", {MERGE: SHA})
        for parents in ({}, {MERGE: "c" * 40}):
            with self.subTest(parents=parents), self.assertRaises(ValueError):
                CHECKS.validate_analyses(analyses(), language_jobs(), SHA, "refs/pull/114/merge", parents)

    def test_failed_empty_stale_or_missing_analysis_rejects_green_jobs(self):
        for data in (analyses(error="extractor failed"), analyses(rules_count=0),
                     analyses(created_at="2026-10-08T20:01:00Z"), analyses()[:-1],
                     analyses(analysis_key="other-workflow:analyze"), analyses(ref="refs/heads/main")):
            with self.subTest(data=data), self.assertRaises(ValueError):
                CHECKS.validate_analyses(data, language_jobs(), SHA, "refs/pull/114/merge", {MERGE: SHA})

    def test_partial_rerun_accepts_retained_successful_language_analyses(self):
        jobs = language_jobs()
        jobs["Analyze (swift)"]["started_at"] = "2026-10-09T21:00:00Z"
        data = analyses()
        next(entry for entry in data if entry["category"] == "/language:swift")["created_at"] = "2026-10-09T21:01:00Z"
        CHECKS.validate_analyses(data, jobs, SHA, "refs/pull/114/merge", {MERGE: SHA})
        with self.assertRaisesRegex(ValueError, "predates its successful language job"):
            CHECKS.validate_analyses(analyses(), jobs, SHA, "refs/pull/114/merge", {MERGE: SHA})

    def test_missing_or_invalid_language_timestamps_fail_closed(self):
        for timestamp in (None, "", "not-a-date", "2026-10-09T20:00:00", "2026-99-09T20:00:00Z"):
            with self.subTest(timestamp=timestamp):
                with self.assertRaisesRegex(ValueError, "invalid timestamp"):
                    CHECKS.validate_analyses(analyses(), language_jobs(started_at=timestamp),
                                            SHA, "refs/pull/114/merge", {MERGE: SHA})
                with self.assertRaisesRegex(ValueError, "invalid timestamp"):
                    CHECKS.validate_analyses(analyses(created_at=timestamp), language_jobs(),
                                            SHA, "refs/pull/114/merge", {MERGE: SHA})

    def test_partial_rerun_passes_complete_gate_unless_alerts_are_open(self):
        jobs = language_jobs()
        jobs["Analyze (swift)"]["started_at"] = "2026-10-09T21:00:00Z"
        data = analyses()
        next(entry for entry in data if entry["category"] == "/language:swift")["created_at"] = "2026-10-09T21:01:00Z"
        alerts = []

        def objects(path):
            if path.startswith("actions/workflows/"):
                workflow = next(value for value in CHECKS.REQUIRED if value.replace("/", "%2F") in path)
                return {"path": workflow, "state": "active", "id": 2 if workflow == WORKFLOW else 3}
            return {"parents": [{"sha": "c" * 40}, {"sha": SHA}]}

        def pages(path):
            if "/runs?" in path:
                workflow = WORKFLOW if "/2/" in path else ".github/workflows/verify.yml"
                return [{"workflow_runs": [run(workflow_id=2 if workflow == WORKFLOW else 3, path=workflow,
                                              run_attempt=2, run_started_at="2026-10-09T21:00:00Z")]}]
            if "/jobs?" in path:
                return [{"jobs": [*jobs.values(), {"name": "macOS", "head_sha": SHA,
                                                  "status": "completed", "conclusion": "success"}]}]
            if "analyses?" in path:
                return [data]
            return [alerts]

        with patch.object(CHECKS, "object_api", side_effect=objects), patch.object(CHECKS, "api", side_effect=pages):
            CHECKS.check(SHA)
            alerts.append({"number": 42})
            with self.assertRaisesRegex(ValueError, "open code-scanning alerts"):
                CHECKS.check(SHA)

    def test_gh_failure_garbage_or_empty_answers_authorize_nothing(self):
        for result, message in ((subprocess.CompletedProcess([], 1, "", "x"), "lookup failed"),
                                (subprocess.CompletedProcess([], 0, "not json", ""), "invalid data"),
                                (subprocess.CompletedProcess([], 0, "[]", ""), "no data"),
                                (subprocess.CompletedProcess([], 0, '{"a": 1}', ""), "no data")):
            with self.subTest(message=message), patch.object(CHECKS.subprocess, "run", return_value=result):
                with self.assertRaisesRegex(ValueError, message):
                    CHECKS.api("x")
        ok = subprocess.CompletedProcess([], 0, '[{"id": 1}]', "")
        with patch.object(CHECKS.subprocess, "run", return_value=ok) as called:
            self.assertEqual(CHECKS.object_api("p"), {"id": 1})
        self.assertEqual(called.call_args.args[0][:4], ["gh", "api", "--paginate", "--slurp"])
        for pages in ([{"a": 1}, {"b": 2}], [[1]]):
            with self.subTest(pages=pages), patch.object(CHECKS, "api", return_value=pages):
                with self.assertRaisesRegex(ValueError, "unexpected GitHub object"):
                    CHECKS.object_api("p")

    def test_analysis_ref_needs_one_pull_request_or_a_safe_branch(self):
        self.assertEqual(CHECKS.analysis_ref(run()), "refs/pull/114/merge")
        self.assertEqual(CHECKS.analysis_ref({"event": "push", "head_branch": "release/1.0"}), "refs/heads/release/1.0")
        for bad in (run(pull_requests=[]), run(pull_requests=[{"number": 1}, {"number": 2}]),
                    run(pull_requests=[{"number": "1"}]), {"event": "push", "head_branch": "a b"},
                    {"event": "push", "head_branch": "x;rm"}, {"event": "push"}):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                CHECKS.analysis_ref(bad)

    def test_inactive_or_misnamed_workflow_stops_the_gate(self):
        for metadata in ({"path": "other.yml", "state": "active", "id": 1},
                         {"path": ".github/workflows/verify.yml", "state": "disabled_manually", "id": 1}):
            with self.subTest(metadata=metadata), patch.object(CHECKS, "object_api", return_value=metadata):
                with self.assertRaisesRegex(ValueError, "not active"):
                    CHECKS.check(SHA)

    def test_missing_or_unexpected_runs_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "missing checks"):
            CHECKS.latest_run([run(head_sha=MERGE)], WORKFLOW, SHA, 2)
        with self.assertRaisesRegex(ValueError, "unexpected check trigger"):
            CHECKS.latest_run([run(event="schedule")], WORKFLOW, SHA, 2)

    def test_languages_must_agree_on_one_commit(self):
        data = analyses()
        data[0]["commit_sha"] = "d" * 40
        with self.assertRaisesRegex(ValueError, "different commit"):
            CHECKS.validate_analyses(data, language_jobs(), SHA, "refs/pull/114/merge", {MERGE: SHA})
        data = analyses()
        data[0]["commit_sha"] = SHA
        with self.assertRaisesRegex(ValueError, "different commits"):
            CHECKS.validate_analyses(data, language_jobs(), SHA, "refs/pull/114/merge", {MERGE: SHA})

    def test_main_requires_a_full_lowercase_sha_and_reports_failures(self):
        for argv, code in (([SHA.upper()], 1), (["abc"], 1)):
            err = io.StringIO()
            with patch.object(sys, "argv", ["x", *argv]), patch.object(CHECKS, "check") as check, \
                    contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as caught:
                CHECKS.main()
            self.assertEqual(caught.exception.code, code)
            self.assertIn("full lowercase", err.getvalue())
            check.assert_not_called()
        err = io.StringIO()
        with patch.object(sys, "argv", ["x", SHA]), patch.object(CHECKS, "check", side_effect=ValueError("red")), \
                contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as caught:
            CHECKS.main()
        self.assertEqual((caught.exception.code, err.getvalue()), (1, "ERR: red\n"))
        out = io.StringIO()
        with patch.object(sys, "argv", ["x", SHA]), patch.object(CHECKS, "check") as check, \
                contextlib.redirect_stdout(out):
            CHECKS.main()
        check.assert_called_once_with(SHA)
        self.assertIn("passed Verify", out.getvalue())


if __name__ == "__main__":
    unittest.main()
