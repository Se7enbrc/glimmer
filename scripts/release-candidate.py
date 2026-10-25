#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Cut the next release candidate for the pushed, reviewed HEAD (`make rc`).

A labelled pull request runs the same cut in CI with --ci-sha once its checks pass: the app
tags as itself and the approval link goes to the pull request instead of a browser."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

from release_validation import SPARKLE, validate_feed
from release_candidate_kind import parse_tag
import candidate_reservation

SCRIPTS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("release_checks", SCRIPTS / "release-checks.py")
CHECKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKS)
FEED_BRANCH = "appcast"
BRANCH = "release-candidate"
# Candidate workflows execute before protected tooling takes over, so these must already be reviewed on main.
RELEASE_PATHS = (".github/workflows/release.yml", ".github/workflows/release-publication.yml",
                 "scripts/ci-release.sh", "scripts/install-ci-scanner.sh", "scripts/release-checks.py",
                 "scripts/release_publication.py", "scripts/release_artifact.py", "scripts/release_validation.py",
                 "scripts/release_candidate_kind.py", "scripts/release_symbols.py", "scripts/candidate_reservation.py",
                 "scripts/candidate_delivery.py", ".github/workflows/candidate-delivery.yml",
                 ".github/workflows/verify.yml", ".github/workflows/codeql.yml",
                 ".github/workflows/ios-testflight-build.yml", "scripts/ios-testflight.py",
                 "scripts/ios-testflight-artifact.py", "scripts/ios-testflight-sign.py",
                 ".github/actions/build-cache/action.yml", ".github/workflows/portable-checks.yml",
                 "scripts/install-ci-linux-tools.sh", "scripts/install-ci-auditor.sh",
                 "scripts/ci-python-requirements.txt", "scripts/coverage-requirements.txt",
                 "scripts/ci-checks.mk", "scripts/mac-test-products.mk", "scripts/test-scripts.py",
                 ".github/actions/cache-save/action.yml", "scripts/cache-budget.py")
POLL_SECONDS = 60
TIMEOUT_SECONDS = 90 * 60


def output(args, message=None):
    result = subprocess.run(args, capture_output=True, text=True, timeout=300)
    if result.returncode:
        if message is None:
            return ""
        raise ValueError(message)
    return result.stdout.strip()


def step(dry_run, args, message):
    print(f"{'Would run' if dry_run else 'Running'}: {shlex.join(args)}", flush=True)
    if not dry_run and subprocess.run(args, timeout=300).returncode:
        raise ValueError(message)


def remote_refs(*patterns):
    refs = {}
    for line in output(["git", "ls-remote", "origin", *patterns], "couldn't list origin's refs").splitlines():
        sha, ref = line.split("\t")
        refs[ref.removesuffix("^{}")] = sha  # Peeled lines follow and win.
    return refs


def release_runs(sha):
    runs = json.loads(output(["gh", "run", "list", "--workflow", "release.yml", "--branch", BRANCH,
                              "--event", "workflow_dispatch", "--json", "databaseId,headSha,url",
                              "--limit", "50"], "couldn't list Release workflow runs"))
    return [run for run in runs if run.get("headSha") == sha]


def show(url, dry_run, pr=None):
    print(f"Release run: {url}")
    print("Remaining step: approve the protected `release` deployment on that page.")
    if dry_run:
        return
    if pr:
        body = f"Release candidate dispatched: {url}\n\nApprove the protected `release` deployment there to build it."
        output(["gh", "pr", "comment", str(pr), "--body", body], "couldn't comment the run on the pull request")
    elif sys.platform == "darwin":
        subprocess.run(["open", url], timeout=30)


def check_build(version, build):
    output(["git", "fetch", "--quiet", "origin", f"+refs/heads/{FEED_BRANCH}:refs/remotes/origin/{FEED_BRANCH}"],
           "couldn't fetch the appcast branch")
    channel = ET.fromstring(output(["git", "show", f"refs/remotes/origin/{FEED_BRANCH}:appcast.xml"],
                                   "couldn't read the appcast")).find("channel")
    if channel is None:
        raise ValueError("appcast has no channel")
    builds = [int(text) for text in (item.findtext(f"{{{SPARKLE}}}version", "") for item in channel.findall("item"))
              if text.isdigit()]
    if builds and int(build) <= max(builds):
        raise ValueError(f"CURRENT_PROJECT_VERSION {build} must exceed published build {max(builds)}; bump it")
    validate_feed(channel, version, build, "rc")


def checks_pending(sha):
    pages = json.loads(output(["gh", "api", "--paginate", "--slurp",
                               f"repos/{CHECKS.REPO}/commits/{sha}/check-runs?per_page=100"],
                              "couldn't list check runs"))
    latest = {}
    for run in sorted((run for page in pages for run in page.get("check_runs", [])), key=lambda r: r.get("id", 0)):
        latest[run.get("name")] = run
    names = set().union(*CHECKS.REQUIRED.values())
    return any(latest.get(name, {}).get("status") != "completed" for name in names)


def wait_for_checks(sha, dry_run):
    started = time.monotonic()
    while True:
        result = subprocess.run([sys.executable, str(SCRIPTS / "release-checks.py"), sha],
                                capture_output=True, text=True, timeout=600)
        if result.returncode == 0:
            print(f"Required checks passed for {sha}")
            return
        reason = (result.stderr or result.stdout).strip().removeprefix("ERR: ") or "release checks failed"
        if not checks_pending(sha):
            raise ValueError(f"required checks failed for {sha}: {reason}")
        minutes = int(time.monotonic() - started) // 60
        if dry_run:
            print(f"Checks pending ({reason}); would wait up to {TIMEOUT_SECONDS // 60} min")
            return
        if minutes >= TIMEOUT_SECONDS // 60:
            raise ValueError(f"checks still pending after {minutes} min: {reason}")
        print(f"Waiting for checks on {sha[:12]}: {reason} ({minutes} min elapsed)", flush=True)
        time.sleep(POLL_SECONDS)


def prepare_reviewed(sha, dry_run, pr=None):
    _, held = candidate_reservation.snapshot()
    if not held or held['state'] != 'reserved' or held['sha'] != sha:
        wait_for_checks(sha, dry_run)
        if pr and output(["gh", "pr", "view", str(pr), "--json", "headRefOid", "-q", ".headRefOid"],
                         "couldn't read the pull request head") != sha:
            raise ValueError(f"pull request #{pr} moved past {sha[:12]}; its new head gets its own candidate")
    prepare_candidate(sha, dry_run)


def candidate_runs(sha, workflow):
    pages = CHECKS.api(f"actions/workflows/{workflow}/runs?head_sha={sha}&per_page=100")
    if any(page.get("total_count", 0) >= 1000 for page in pages):
        raise ValueError("candidate run search may be truncated")
    return [run for page in pages for run in page.get("workflow_runs", [])
            if run.get("event") == "workflow_dispatch" and run.get("head_branch") == BRANCH
            and run.get("head_sha") == sha]


def prepare_candidate(sha, dry_run):
    fresh = candidate_reservation.reserve(sha, dry_run, CHECKS)
    minimum = {}
    for workflow in CHECKS.REQUIRED:
        runs = candidate_runs(sha, workflow.rsplit("/", 1)[1])
        if fresh or not runs:
            minimum[workflow] = max((run["id"] for run in runs), default=0)
            step(dry_run, ["gh", "workflow", "run", workflow.rsplit("/", 1)[1], "--ref", BRANCH],
                 f"couldn't dispatch {workflow}; reservation retained, rerun the cutter")
    if dry_run:
        print("Would wait up to 45 min for direct candidate Verify, CodeQL processing and alert checks")
        return
    deadline = time.monotonic() + 45 * 60
    while time.monotonic() < deadline:
        try:
            with CHECKS.read_budget(deadline):
                for workflow, previous in minimum.items():
                    runs = candidate_runs(sha, workflow.rsplit("/", 1)[1])
                    if not any(run["id"] > previous for run in runs):
                        raise CHECKS.ChecksPending(f"waiting for dispatched {workflow}")
                CHECKS.check(sha, candidate=True)
            return
        except CHECKS.ChecksPending as error:
            print(f"Waiting for candidate evidence: {error}", flush=True)
        time.sleep(min(POLL_SECONDS, max(0, deadline - time.monotonic())))
    raise ValueError("candidate checks timed out; reservation retained, rerun failed jobs or resume the cutter")


def signed(tag):
    body = output(["git", "cat-file", "tag", f"refs/tags/{tag}"])
    return re.search(r"^-----BEGIN [A-Z ]*SIGNATURE-----$", body, re.M) is not None


def reviewed_head():
    if output(["git", "status", "--porcelain"], "couldn't read the working tree"):
        raise ValueError("working tree is not clean; commit, stash or remove changes first")
    branch = output(["git", "symbolic-ref", "--quiet", "--short", "HEAD"], "HEAD is detached; check out the PR branch")
    output(["git", "fetch", "--quiet", "origin"], "git fetch origin failed")
    sha = output(["git", "rev-parse", "HEAD"], "couldn't resolve HEAD")
    pushed = output(["git", "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{branch}"])
    if pushed != sha:
        raise ValueError(f"HEAD {sha[:12]} is not pushed; origin/{branch} is {pushed[:12] or 'missing'}")
    return sha, branch


def candidate_tag(version, build, sha, tags, diagnostic):
    candidates = {}
    for name in tags:
        try:
            candidates[name] = parse_tag(name)
        except ValueError:
            continue
    current = []
    for name, (_, number, is_diagnostic) in candidates.items():
        if tags[name] == sha:
            if is_diagnostic != diagnostic:
                raise ValueError("source already has a different candidate kind; bump the build and commit first")
            current.append((number, name))
        elif is_diagnostic:
            # Off-feed diagnostics still consume a build identity.
            output(["git", "fetch", "--quiet", "origin", f"refs/tags/{name}"], "cannot read diagnostic source")
            config = output(["git", "show", f"{tags[name]}:Glimmer/Version.xcconfig"],
                            "cannot read diagnostic build number")
            match = re.search(r"^CURRENT_PROJECT_VERSION\s*=\s*([1-9][0-9]*)\s*$", config, re.M)
            if match is None or int(build) <= int(match[1]):
                raise ValueError(f"build {build} must exceed diagnostic candidate {name}")
    if current:
        return max(current)[1], True
    number = max((values[1] for values in candidates.values() if values[0] == version), default=0) + 1
    return f"{version}-rc.{number}{'-diag' if diagnostic else ''}", False


def cut(dry_run, ci_sha=None, pr=None, diagnostic=False, prepare_only=False):
    if ci_sha:
        # CI never checks out the pull request; it reads the candidate commit from history.
        sha, branch = ci_sha, f"pull request #{pr}"
        output(["git", "cat-file", "-e", f"{sha}^{{commit}}"], f"commit {sha[:12]} is not in this clone")
    else:
        sha, branch = reviewed_head()
    output(["git", "fetch", "--quiet", "origin", "main"], "couldn't fetch main; nothing cut")
    output(["git", "diff", "--quiet", "origin/main", sha, "--", *RELEASE_PATHS],
           "candidate release workflow or script differs from main; "
           "land workflow and release-script changes on main first")
    if prepare_only:
        prepare_reviewed(sha, dry_run)
        state = "would be prepared" if dry_run else "prepared"
        print(f"Candidate {sha} {state} for credential-free iOS archive dispatch on {BRANCH}")
        return
    config = output(["git", "show", f"{sha}:Glimmer/Version.xcconfig"], "couldn't read the candidate version")
    values = dict(re.findall(r"^(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)\s*$", config, re.M))
    version, build = values["MARKETING_VERSION"], values["CURRENT_PROJECT_VERSION"]
    tags = {ref.removeprefix("refs/tags/"): target for ref, target in remote_refs("refs/tags/*").items()}
    if version in tags:
        raise ValueError(f"{version} already has a final tag; bump MARKETING_VERSION")
    tag, current = candidate_tag(version, build, sha, tags, diagnostic)
    if current:
        if runs := release_runs(sha):
            print(f"{tag} already identifies {sha} and has a Release run.")
            show(runs[0]["url"], dry_run, pr)
            return
    local = output(["git", "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}^{{commit}}"])
    if local and local != sha:
        raise ValueError(f"tag {tag} already identifies {local[:12]}, not {sha[:12]}; tags are never replaced")
    print(f"Candidate {tag}: {version} build {build} at {sha} ({branch})")
    check_build(version, build)
    prepare_reviewed(sha, dry_run, pr if ci_sha else None)
    if tag not in tags:
        if ci_sha and not local:
            # The release app tags as itself; its token and the run's attestation identify it.
            step(dry_run, ["git", "tag", "-a", tag, sha, "-m", tag], "couldn't create the candidate tag")
        elif not local:
            step(dry_run, ["git", "tag", "-s", tag, sha, "-m", tag], "tag signing failed; refusing an unsigned tag")
        if not dry_run and not ci_sha and not signed(tag):
            raise ValueError(f"tag {tag} is not signed; refusing to push it")
        step(dry_run, ["git", "push", "origin", f"refs/tags/{tag}"], f"couldn't push {tag}")
    before = {run["databaseId"] for run in release_runs(sha)}
    step(dry_run, ["gh", "workflow", "run", "release.yml", "--ref", BRANCH, "-f", "operation=candidate",
                   "-f", f"expected_sha={sha}", "-f", f"rc_tag={tag}"], "couldn't dispatch the Release workflow")
    if dry_run:
        print("Would open the new Release run to approve its protected `release` deployment.")
        return
    for _ in range(30):
        if new := [run for run in release_runs(sha) if run["databaseId"] not in before]:
            show(new[0]["url"], dry_run, pr)
            return
        time.sleep(2)
    raise ValueError("dispatched, but the new Release run didn't appear; check the Actions tab")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="print every step without pushing, tagging or dispatching")
    parser.add_argument("--prepare-only", action="store_true", help="reserve and scan for iOS without tagging or releasing Mac")
    parser.add_argument("--diagnostic", action="store_true", help="manual-install diagnostic candidate; never promoted")
    parser.add_argument("--ci-sha", help="CI only: the labelled pull request head to cut")
    parser.add_argument("--pr", type=int, help="CI only: the pull request to comment the run on")
    args = parser.parse_args()
    if bool(args.ci_sha) != bool(args.pr) or (args.ci_sha and not re.fullmatch(r"[0-9a-f]{40}", args.ci_sha)):
        parser.error("--ci-sha needs a full commit SHA and --pr")
    if args.prepare_only and (args.ci_sha or args.diagnostic):
        parser.error("--prepare-only is a local preparation for both platforms, without --ci-sha or --diagnostic")
    os.chdir(SCRIPTS.parent)
    try:
        cut(args.dry_run, args.ci_sha, args.pr, args.diagnostic, args.prepare_only)
    except (ValueError, KeyError, OSError, ET.ParseError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"ERR: {error}\n")


if __name__ == "__main__":
    main()
