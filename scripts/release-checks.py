#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Require successful upstream verification and analysis for a reviewed commit."""

import argparse
from datetime import datetime
import json
import re
import subprocess
import sys
from urllib.parse import quote

REPO = "Se7enbrc/glimmer"
REQUIRED = {
    ".github/workflows/verify.yml": {"macOS"},
    ".github/workflows/codeql.yml": {"Analyze (swift)", "Analyze (python)", "Analyze (actions)"},
}
CATEGORIES = {f"/language:{language}": f"Analyze ({language})"
              for language in ("swift", "python", "actions")}


def api(path):
    result = subprocess.run(["gh", "api", "--paginate", "--slurp", f"repos/{REPO}/{path}"],
                            capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise ValueError("GitHub check lookup failed; nothing authorized")
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


def latest_run(runs, workflow, sha, workflow_id):
    eligible = [run for run in runs if run.get("head_sha") == sha
                and run.get("workflow_id") == workflow_id and run.get("path") == workflow]
    if not eligible:
        raise ValueError(f"missing checks: {workflow}")
    run = max(eligible, key=lambda item: (item.get("run_number", 0), item.get("run_attempt", 0)))
    if run.get("head_repository", {}).get("full_name") != REPO:
        raise ValueError("checks did not originate from the upstream repository")
    if run.get("event") not in {"push", "pull_request", "workflow_dispatch"}:
        raise ValueError("unexpected check trigger")
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        raise ValueError(f"checks are not green: {workflow}")
    return run


def validate_jobs(jobs, required, sha):
    validated = {}
    for name in required:
        matches = [job for job in jobs if job.get("name") == name]
        if len(matches) != 1 or matches[0].get("head_sha") != sha:
            raise ValueError(f"missing exact-commit job: {name}")
        if matches[0].get("status") != "completed" or matches[0].get("conclusion") != "success":
            raise ValueError(f"job is not green: {name}")
        validated[name] = matches[0]
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
        commit = entry.get("commit_sha")
        if commit != sha and parents.get(commit) != sha:
            raise ValueError("CodeQL analyzed a different commit")
        commits.add(commit)
    if len(commits) != 1:
        raise ValueError("CodeQL languages analyzed different commits")


def check(sha):
    codeql_run = None
    codeql_jobs = {}
    for workflow, required in REQUIRED.items():
        metadata = object_api(f"actions/workflows/{quote(workflow, safe='')}")
        if metadata.get("path") != workflow or metadata.get("state") != "active":
            raise ValueError("required workflow is not active")
        pages = api(f"actions/workflows/{metadata['id']}/runs?head_sha={sha}&per_page=100")
        runs = [run for page in pages for run in page.get("workflow_runs", [])]
        run = latest_run(runs, workflow, sha, metadata["id"])
        pages = api(f"actions/runs/{run['id']}/jobs?filter=latest&per_page=100")
        jobs = validate_jobs([job for page in pages for job in page.get("jobs", [])], required, sha)
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
    for commit in {entry.get("commit_sha") for entry in latest}:
        if commit != sha and isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit):
            info = object_api(f"git/commits/{commit}")
            if len(info.get("parents", [])) == 2:
                parents[commit] = info["parents"][1].get("sha")
    validate_analyses(analyses, codeql_jobs, sha, ref, parents)
    pages = api(f"code-scanning/alerts?state=open&ref={quote(ref, safe='')}&per_page=100")
    if any(page for page in pages):
        raise ValueError("open code-scanning alerts must be resolved before release")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sha")
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[0-9a-f]{40}", args.sha):
            raise ValueError("reviewed SHA must be a full lowercase commit SHA")
        check(args.sha)
    except (ValueError, KeyError, TypeError, subprocess.TimeoutExpired, OSError) as error:
        parser.exit(1, f"ERR: {error}\n")
    print("Reviewed commit passed Verify, all CodeQL languages and code-scanning alert checks.")


if __name__ == "__main__":
    main()
