"""The candidate gate rejects missing, stale or unsuccessful upstream checks."""

import importlib.util
from pathlib import Path
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
                                                  "status": "completed", "conclusion": "success"}]}]
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


if __name__ == "__main__":
    unittest.main()
