# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""The candidate gate rejects missing, stale or unsuccessful upstream checks."""

import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import json
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))

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
            "updated_at": "2026-10-09T20:02:00Z",
            "run_started_at": "2026-10-09T20:00:00Z", "pull_requests": [{"number": 114}], **changes}


def analyses(**changes):
    return [{"id": index, "category": category, "analysis_key": f"{WORKFLOW}:analyze",
             "ref": "refs/pull/114/merge", "commit_sha": MERGE, "error": "", "rules_count": 10,
             "created_at": "2026-10-09T20:01:00Z", "sarif_id": f"upload-{index}", **changes}
            for index, category in enumerate(sorted(CHECKS.CATEGORIES), 1)]


def language_jobs(**changes):
    return {name: {"name": name, "head_sha": SHA, "status": "completed", "conclusion": "success",
                   "run_id": 1, "run_attempt": 1, "head_branch": None,
                   "completed_at": "2026-10-09T20:02:00Z",
                   "started_at": "2026-10-09T20:00:00Z",
                   "steps": [{"name": f"CodeQL upload upload-{index}",
                              "status": "completed", "conclusion": "success"}], **changes}
            for index, name in enumerate(sorted(CHECKS.REQUIRED[WORKFLOW]), 1)}


class RequiredChecksTests(unittest.TestCase):
    def setUp(self):
        clock = patch.object(CHECKS, 'time')
        clock.start().monotonic.return_value = 0
        self.addCleanup(clock.stop)

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
        jobs["Analyze (swift)"].update(started_at="2026-10-09T21:00:00Z",
                                      completed_at="2026-10-09T21:02:00Z")
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
        jobs["Analyze (swift)"].update(started_at="2026-10-09T21:00:00Z",
                                      completed_at="2026-10-09T21:02:00Z")
        data = analyses()
        next(entry for entry in data if entry["category"] == "/language:swift")["created_at"] = "2026-10-09T21:01:00Z"
        alerts = []
        alert_queries = []

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
                                                  "status": "completed", "conclusion": "success",
                                                  "run_id": 1, "run_attempt": 2, "head_branch": None}]}]
            if "analyses?" in path:
                return [data]
            alert_queries.append(path)
            return [alerts]

        with patch.object(CHECKS, "object_api", side_effect=objects), patch.object(CHECKS, "api", side_effect=pages):
            CHECKS.check(SHA)
            self.assertIn("tool_name=CodeQL", alert_queries[0])
            alerts.append({"number": 42})
            with self.assertRaisesRegex(ValueError, "open CodeQL alerts"):
                CHECKS.check(SHA)

    def test_success_records_exact_prerequisites_and_failure_records_nothing(self):
        evidence = {"sha": SHA, "runs": [{"workflow": WORKFLOW, "id": 123, "attempt": 2}]}
        with tempfile.TemporaryDirectory() as directory:
            proof, summary = Path(directory) / "proof.json", Path(directory) / "summary.md"
            env = {"RELEASE_CHECKS_FILE": str(proof), "GITHUB_STEP_SUMMARY": str(summary)}
            with patch.dict(CHECKS.os.environ, env), patch.object(sys, "argv", ["x", SHA]), \
                    patch.object(CHECKS, "check", return_value=evidence), contextlib.redirect_stdout(io.StringIO()):
                CHECKS.main()
            self.assertEqual(json.loads(proof.read_text()), evidence)
            self.assertIn("actions/runs/123", summary.read_text())
            self.assertIn("attempt 2", summary.read_text())
            proof.unlink()
            with patch.dict(CHECKS.os.environ, env), patch.object(sys, "argv", ["x", SHA]), \
                    patch.object(CHECKS, "check", side_effect=ValueError("failed")), \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                CHECKS.main()
            self.assertFalse(proof.exists())

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
        with patch.object(sys, "argv", ["x", SHA]), \
                patch.object(CHECKS, "check", return_value={"sha": SHA, "runs": []}) as check, \
                patch.dict(CHECKS.os.environ, {"GITHUB_STEP_SUMMARY": "", "RELEASE_CHECKS_FILE": ""}), \
                contextlib.redirect_stdout(out):
            CHECKS.main()
        check.assert_called_once_with(SHA)
        self.assertIn("passed Verify", out.getvalue())


class GitHubReadRetryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # Keep timing mocks out of subprocess.wait's polling loop.
        execute = patch.object(CHECKS.subprocess, 'run', side_effect=self.execute)
        execute.start()
        self.addCleanup(execute.stop)
        clock = patch.object(CHECKS, 'time')
        timing = clock.start()
        timing.monotonic.return_value = 0
        self.sleep = timing.sleep
        self.addCleanup(clock.stop)

    def responses(self, *responses):
        self.results = responses
        self.requests = []
        self.sleep.reset_mock()

    def execute(self, args, **kwargs):
        self.requests.append(args[1:])
        response = self.results[min(len(self.requests) - 1, len(self.results) - 1)]
        return subprocess.CompletedProcess(args, response['returncode'], response['stdout'], response['stderr'])

    def calls(self):
        return self.requests

    def test_fake_gh_recovers_transient_failure_on_the_same_endpoint(self):
        success = {'returncode': 0, 'stdout': '[{"id": 1}]', 'stderr': ''}
        for error in ('gh: Service Unavailable (HTTP 503)', 'read tcp: connection reset by peer',
                      'error connecting to api.github.com', 'Get https://api.github.com: EOF'):
            with self.subTest(error=error):
                self.responses({'returncode': 1, 'stdout': '[{"partial": true}]', 'stderr': error}, success)
                self.assertEqual(CHECKS.object_api('actions/workflows/1'), {'id': 1})
                calls = self.calls()
                self.assertEqual(len(calls), 2)
                self.assertEqual(calls[0], calls[1])
                self.sleep.assert_called_once_with(0.25)

    def test_fake_gh_exhaustion_never_writes_authorization(self):
        self.responses({'returncode': 1, 'stdout': '', 'stderr': 'gh: Bad Gateway (HTTP 502)'})
        proof = self.root / 'proof.json'
        with patch.dict(CHECKS.os.environ, RELEASE_CHECKS_FILE=str(proof)), \
                patch.object(sys, 'argv', ['release-checks.py', SHA]), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            CHECKS.main()
        self.assertEqual(len(self.calls()), 3)
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [0.25, 0.5])
        self.assertFalse(proof.exists())

    def test_permanent_http_and_invalid_data_are_not_retried(self):
        for response in (
                {'returncode': 1, 'stdout': '', 'stderr': 'gh: Unauthorized (HTTP 401)'},
                {'returncode': 1, 'stdout': '', 'stderr': 'gh: Forbidden (HTTP 403)'},
                {'returncode': 1, 'stdout': '', 'stderr': 'gh: Not Found (HTTP 404)'},
                {'returncode': 4, 'stdout': '', 'stderr': 'authentication required'},
                {'returncode': 1, 'stdout': '', 'stderr': 'unknown flag'},
                {'returncode': 0, 'stdout': 'not json', 'stderr': ''},
                {'returncode': 0, 'stdout': '[]', 'stderr': ''}):
            with self.subTest(response=response):
                self.responses(response)
                with self.assertRaises(ValueError) as error:
                    CHECKS.api('actions/workflows/1')
                if response['stderr']:
                    self.assertNotIn(response['stderr'], str(error.exception))
                self.assertEqual(len(self.calls()), 1)
                self.sleep.assert_not_called()

    def test_missing_or_red_checks_are_authoritative_without_retry(self):
        workflow = '.github/workflows/verify.yml'
        metadata = {'path': workflow, 'state': 'active', 'id': 3}
        for runs in ([], [run(path=workflow, workflow_id=3, conclusion='failure')]):
            with self.subTest(runs=runs):
                self.responses({'returncode': 0, 'stdout': json.dumps([metadata]), 'stderr': ''},
                               {'returncode': 0, 'stdout': json.dumps([{'workflow_runs': runs}]), 'stderr': ''})
                with self.assertRaisesRegex(ValueError, 'missing checks|not green'):
                    CHECKS.check(SHA)
                self.assertEqual(len(self.calls()), 2)
                self.sleep.assert_not_called()

    def test_timeout_can_recover_but_repeated_timeouts_fail_closed(self):
        timeout = subprocess.TimeoutExpired('gh', 20)
        success = subprocess.CompletedProcess([], 0, '[{"id": 1}]', '')
        with patch.object(CHECKS.subprocess, 'run', side_effect=[timeout, success]) as execute:
            self.assertEqual(CHECKS.object_api('actions/workflows/1'), {'id': 1})
        self.assertEqual(execute.call_count, 2)
        self.assertTrue(all(call.kwargs['timeout'] <= 20 for call in execute.call_args_list))
        self.sleep.reset_mock()
        with patch.object(CHECKS.subprocess, 'run', side_effect=timeout) as execute:
            with self.assertRaisesRegex(ValueError, 'lookup failed.*nothing authorized'):
                CHECKS.api('actions/workflows/1')
        self.assertEqual(execute.call_count, 3)

    def test_total_read_budget_stops_retries_and_bounds_subprocess_timeout(self):
        failure = subprocess.CompletedProcess([], 1, '', 'gh: Bad Gateway (HTTP 502)')
        with patch.object(CHECKS.time, 'monotonic', side_effect=[0, 0, 60]), \
                patch.object(CHECKS.subprocess, 'run', return_value=failure) as execute:
            with self.assertRaisesRegex(ValueError, 'lookup failed.*nothing authorized'):
                CHECKS.api('actions/workflows/1')
        self.assertEqual(execute.call_count, 1)
        self.assertLessEqual(execute.call_args.kwargs['timeout'], 60)
        self.sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
