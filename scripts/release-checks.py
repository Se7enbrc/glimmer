#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Require successful upstream verification and analysis for a reviewed commit."""

import argparse
from contextlib import contextmanager
from contextvars import ContextVar
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.parse import quote

import candidate_reservation

REPO = "Se7enbrc/glimmer"
READ_DEADLINE = ContextVar("release_read_deadline", default=float("inf"))
REQUIRED = {
    ".github/workflows/verify.yml": {"macOS", "Tier 2"},
    ".github/workflows/codeql.yml": {"Analyze (swift)", "Analyze (python)", "Analyze (actions)"},
}
CATEGORIES = {f"/language:{language}": f"Analyze ({language})"
              for language in ("swift", "python", "actions")}


class ChecksPending(ValueError):
    """Incomplete candidate evidence may be retried within the cutter deadline."""


@contextmanager
def read_budget(deadline):
    token = READ_DEADLINE.set(min(deadline, READ_DEADLINE.get()))
    try:
        yield
    finally:
        READ_DEADLINE.reset(token)


def api(path):
    deadline = min(time.monotonic() + 60, READ_DEADLINE.get())
    for attempt in range(3):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError("GitHub check lookup failed (deadline); nothing authorized")
        try:
            result = subprocess.run(["gh", "api", "--paginate", "--slurp", f"repos/{REPO}/{path}"],
                                    capture_output=True, text=True, timeout=min(20, remaining))
        except subprocess.TimeoutExpired:
            transient, detail = True, "timeout"
        else:
            if not result.returncode:
                break
            status = re.search(r"\bHTTP ([1-5][0-9]{2})\b", result.stderr)
            if status:
                transient = 500 <= int(status[1]) <= 599
                detail = f"HTTP {status[1]}"
            else:
                transient = result.returncode == 1 and re.search(
                    r"timeout|timed out|connection|error connecting|network|no such host|temporary failure|\bEOF\b|TLS handshake",
                    result.stderr, re.I) is not None
                detail = "network failure" if transient else "command failure"
        delay = 0.25 * (2 ** attempt)
        if not transient or attempt == 2 or time.monotonic() + delay >= deadline:
            raise ValueError(f"GitHub check lookup failed ({detail}); nothing authorized")
        time.sleep(delay)
    try:
        pages = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError("GitHub check lookup returned invalid data") from error
    if not isinstance(pages, list) or not pages:
        raise ValueError("GitHub check lookup returned no data")
    return pages


def object_api(path):
    pages = api(path)
    if len(pages) != 1 or not isinstance(pages[0], dict):
        raise ValueError("unexpected GitHub object response")
    return pages[0]


def latest_run(runs, workflow, sha, workflow_id, candidate=False):
    eligible = [run for run in runs if run.get("head_sha") == sha
                and run.get("workflow_id") == workflow_id and run.get("path") == workflow]
    if candidate:
        eligible = [run for run in eligible if run.get("head_branch") == "release-candidate"
                    and run.get("event") == "workflow_dispatch"]
    else:
        eligible = [run for run in eligible if run.get("head_branch") != "release-candidate"]
    if not eligible:
        error = ChecksPending if candidate else ValueError
        raise error(f"missing checks: {workflow}")
    # Run numbers do not change on rerun; a queued older run must also close the gate.
    if any(item.get("status") != "completed" for item in eligible):
        raise ChecksPending(f"checks are pending: {workflow}")
    def execution(item):
        return max(analysis_timestamp(item.get("run_started_at")),
                   analysis_timestamp(item.get("updated_at")))
    newest = max(map(execution, eligible))
    latest = [item for item in eligible if execution(item) == newest]
    if any(item.get("conclusion") != "success" for item in latest):
        raise ValueError(f"checks are not green: {workflow}")
    run = max(latest, key=lambda item: (item.get("run_number", 0), item.get("run_attempt", 0)))
    if not all(type(run.get(key)) is int and run[key] > 0 for key in ("id", "run_attempt")):
        raise ValueError("check run has no execution identity")
    if run.get("head_repository", {}).get("full_name") != REPO:
        raise ValueError("checks did not originate from the upstream repository")
    if run.get("event") not in {"push", "pull_request", "workflow_dispatch", "schedule"}:
        raise ValueError("unexpected check trigger")
    if candidate and run.get("status") != "completed":
        raise ChecksPending(f"checks are pending: {workflow}")
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        raise ValueError(f"checks are not green: {workflow}")
    return run


def validate_jobs(jobs, required, sha, run=None):
    validated = {}
    for name in required:
        matches = [job for job in jobs if job.get("name") == name]
        if len(matches) != 1 or matches[0].get("head_sha") != sha:
            raise ValueError(f"missing exact-commit job: {name}")
        if matches[0].get("status") != "completed" or matches[0].get("conclusion") != "success":
            raise ValueError(f"job is not green: {name}")
        job = matches[0]
        if run is not None and (job.get("run_id") != run["id"]
                                or type(job.get("run_attempt")) is not int
                                or not 1 <= job["run_attempt"] <= run["run_attempt"]
                                or job.get("head_branch") != run.get("head_branch")):
            raise ValueError("job does not belong to the selected run, attempt and ref")
        validated[name] = job
    return validated


def analysis_ref(run):
    if run["event"] == "pull_request":
        requests = run.get("pull_requests", [])
        if len(requests) != 1 or not isinstance(requests[0].get("number"), int):
            raise ValueError("cannot identify the analyzed pull request")
        return f"refs/pull/{requests[0]['number']}/merge"
    branch = run.get("head_branch", "")
    if not re.fullmatch(r"[A-Za-z0-9_./-]+", branch):
        raise ValueError("invalid analyzed branch")
    return f"refs/heads/{branch}"


def analysis_timestamp(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value):
        raise ValueError("CodeQL analysis or successful job has an invalid timestamp")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise ValueError("CodeQL analysis or successful job has an invalid timestamp") from error


def validate_analyses(analyses, jobs, sha, ref, parents):
    relevant = [entry for entry in analyses if entry.get("analysis_key") == ".github/workflows/codeql.yml:analyze"
                and entry.get("ref") == ref and entry.get("category") in CATEGORIES]
    commits = set()
    for category in CATEGORIES:
        entries = [entry for entry in relevant if entry["category"] == category]
        if not entries:
            raise ValueError(f"missing CodeQL analysis: {category}")
        entry = max(entries, key=lambda item: item.get("id", 0))
        if entry.get("error") or not entry.get("rules_count", 0):
            raise ValueError(f"CodeQL analysis is incomplete: {category}")
        # A partial rerun retains successful language jobs from the original attempt.
        started = analysis_timestamp(jobs.get(CATEGORIES[category], {}).get("started_at"))
        created = analysis_timestamp(entry.get("created_at"))
        if created < started:
            raise ValueError("CodeQL analysis predates its successful language job")
        completed = analysis_timestamp(jobs[CATEGORIES[category]].get("completed_at"))
        if created > completed:
            raise ValueError("CodeQL analysis follows its successful language job")
        commit = entry.get("commit_sha")
        if commit != sha and parents.get(commit) != sha:
            raise ValueError("CodeQL analyzed a different commit")
        commits.add(commit)
    if len(commits) != 1:
        raise ValueError("CodeQL languages analyzed different commits")


def validate_uploads(analyses, jobs, candidate):
    for entry in analyses:
        if type(entry.get("id")) is not int or entry["id"] <= 0:
            raise ValueError("analysis has no identity")
        upload = entry.get("sarif_id")
        if not isinstance(upload, str) or not re.fullmatch(r"[A-Za-z0-9-]+", upload):
            raise ValueError("analysis has no upload identity")
        job = jobs[CATEGORIES[entry["category"]]]
        receipts = [step for step in job.get("steps", [])
                    if step.get("name", "").startswith("CodeQL upload ")]
        if (len(receipts) != 1 or receipts[0].get("name") != f"CodeQL upload {upload}"
                or receipts[0].get("status") != "completed"
                or receipts[0].get("conclusion") != "success"):
            raise ValueError("CodeQL upload is not bound to its successful producing job")
        if candidate:
            status = object_api(f"code-scanning/sarifs/{upload}")
            if status.get("processing_status") == "pending":
                raise ChecksPending("candidate CodeQL upload is processing")
            if status.get("processing_status") != "complete" or status.get("errors"):
                raise ValueError("candidate CodeQL upload did not complete")


def collect(sha, candidate=False):
    prerequisite_runs = []
    codeql_run = None
    codeql_jobs = {}
    for workflow, required in REQUIRED.items():
        metadata = object_api(f"actions/workflows/{quote(workflow, safe='')}")
        if metadata.get("path") != workflow or metadata.get("state") != "active":
            raise ValueError("required workflow is not active")
        pages = api(f"actions/workflows/{metadata['id']}/runs?head_sha={sha}&per_page=100")
        if any(page.get("total_count", 0) >= 1000 for page in pages):
            raise ValueError("workflow run search may be truncated; nothing authorized")
        runs = [run for page in pages for run in page.get("workflow_runs", [])]
        run = latest_run(runs, workflow, sha, metadata["id"], candidate)
        prerequisite_runs.append({"workflow": workflow, "id": run["id"], "attempt": run["run_attempt"],
                                  "sha": sha, "ref": analysis_ref(run)})
        pages = api(f"actions/runs/{run['id']}/jobs?filter=latest&per_page=100")
        jobs = validate_jobs([job for page in pages for job in page.get("jobs", [])], required, sha, run)
        if workflow.endswith("codeql.yml"):
            codeql_run = run
            codeql_jobs = jobs
    ref = analysis_ref(codeql_run)
    pages = api(f"code-scanning/analyses?tool_name=CodeQL&ref={quote(ref, safe='')}&per_page=100")
    analyses = [entry for page in pages for entry in page]
    parents = {}
    latest = [max((entry for entry in analyses if entry.get("category") == category
                   and entry.get("analysis_key") == ".github/workflows/codeql.yml:analyze"
                   and entry.get("ref") == ref),
                  key=lambda entry: entry.get("id", 0), default={}) for category in CATEGORIES]
    for commit in (() if candidate else {entry.get("commit_sha") for entry in latest}):
        if commit != sha and isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit):
            info = object_api(f"git/commits/{commit}")
            if len(info.get("parents", [])) == 2:
                parents[commit] = info["parents"][1].get("sha")
    if candidate and any(not entry for entry in latest):
        raise ChecksPending("candidate CodeQL analysis is still missing")
    validate_analyses(analyses, codeql_jobs, sha, ref, parents)
    validate_uploads(latest, codeql_jobs, candidate)
    producers = [{"category": category, "run": job.get("run_id"),
                  "attempt": job.get("run_attempt"), "sha": job["head_sha"], "ref": ref}
                 for category, name in CATEGORIES.items() for job in [codeql_jobs[name]]]
    return {"sha": sha, "runs": prerequisite_runs, "producers": producers, "analysis_ref": ref,
            "analyses": [{key: entry.get(key) for key in ("id", "sarif_id", "category", "commit_sha")}
                         for entry in latest]}


def require_candidate_ref(sha, delivery=False):
    ref = object_api("git/ref/heads/release-candidate")
    if ref.get("object", {}).get("sha") != sha or ref.get("object", {}).get("type") != "commit":
        raise ValueError("release-candidate moved or is missing; nothing authorized")
    return candidate_reservation.require(sha, object_api, delivery=delivery)


def check(sha, candidate=False, delivery=False):
    if delivery and not candidate:
        raise ValueError("delivery admission requires the candidate gate")
    if delivery:
        candidate_reservation.wait(sha, object_api, read_budget)
    reservation = require_candidate_ref(sha, delivery) if candidate else None
    evidence = collect(sha, candidate)
    ref = evidence["analysis_ref"]
    # Code findings gate a release; repository-posture tools like Scorecard report elsewhere.
    pages = api(f"code-scanning/alerts?tool_name=CodeQL&state=open&ref={quote(ref, safe='')}&per_page=100")
    if any(page for page in pages):
        raise ValueError("open CodeQL alerts must be resolved before release")
    if candidate:
        if collect(sha, candidate=True) != evidence:
            raise ValueError("candidate evidence changed during alert lookup")
        if require_candidate_ref(sha, delivery) != reservation:
            raise ValueError("candidate reservation changed during checks")
        evidence["reservation"] = reservation
        if delivery:
            evidence["delivery"] = candidate_reservation.current_delivery()
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sha")
    parser.add_argument("--candidate", action="store_true", help="require direct scans on the held candidate ref")
    parser.add_argument("--delivery", action="store_true", help="require this workflow attempt's durable admission")
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[0-9a-f]{40}", args.sha):
            raise ValueError("reviewed SHA must be a full lowercase commit SHA")
        if args.delivery and not args.candidate:
            raise ValueError("delivery admission requires the candidate gate")
        if args.delivery:
            evidence = check(args.sha, candidate=True, delivery=True)
        else:
            evidence = check(args.sha, candidate=True) if args.candidate else check(args.sha)
        if os.environ.get("RELEASE_CHECKS_FILE"):
            Path(os.environ["RELEASE_CHECKS_FILE"]).write_text(json.dumps(evidence) + "\n")
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
                summary.write(f"Prerequisites passed for `{args.sha}`:\n\n")
                for run in evidence["runs"]:
                    summary.write(f'- [{run["workflow"]}, attempt {run["attempt"]}]'
                                  f'(https://github.com/{REPO}/actions/runs/{run["id"]})\n')
    except ChecksPending as error:
        parser.exit(2, f"ERR: {error}\n")
    except (ValueError, KeyError, TypeError, subprocess.TimeoutExpired, OSError) as error:
        parser.exit(1, f"ERR: {error}\n")
    print("Reviewed commit passed Verify, all CodeQL languages and code-scanning alert checks.")


if __name__ == "__main__":
    main()
