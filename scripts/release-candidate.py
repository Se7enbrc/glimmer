#!/usr/bin/env python3
"""Cut the next release candidate for the pushed, reviewed HEAD (`make rc`)."""

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

SCRIPTS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("release_checks", SCRIPTS / "release-checks.py")
CHECKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKS)
LIVE_APPCAST = "https://se7enbrc.github.io/glimmer/appcast.xml"
BRANCH = "release-candidate"
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


def show(url, dry_run):
    print(f"Release run: {url}")
    print("Remaining step: approve the protected `release` deployment on that page.")
    if not dry_run and sys.platform == "darwin":
        subprocess.run(["open", url], timeout=30)


def check_build(version, build):
    fetched = subprocess.run(["curl", "-fsSL", "--max-time", "30", LIVE_APPCAST],
                             capture_output=True, text=True, timeout=60)
    try:
        root = ET.fromstring(fetched.stdout) if fetched.returncode == 0 else None
    except ET.ParseError:
        root = None
    if root is None:
        print("WARNING: couldn't fetch the live appcast; checking the committed appcast.xml", file=sys.stderr)
        root = ET.parse("appcast.xml").getroot()
    channel = root.find("channel")
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


def point_branch(sha, dry_run):
    old = remote_refs(f"refs/heads/{BRANCH}").get(f"refs/heads/{BRANCH}")
    if old == sha:
        print(f"{BRANCH} is already at {sha}")
        return
    push = ["git", "push", "origin", f"{sha}:refs/heads/{BRANCH}"]
    moved = old and subprocess.run(["git", "merge-base", "--is-ancestor", old, sha]).returncode != 0
    if moved:
        push.insert(2, f"--force-with-lease={BRANCH}:{old}")
    step(dry_run, push, f"couldn't push {BRANCH}")
    if moved:
        print(f"{'Would move' if dry_run else 'Moved'} {BRANCH} from {old[:12]} to {sha[:12]} (not a fast-forward)")


def signed(tag):
    body = output(["git", "cat-file", "tag", f"refs/tags/{tag}"])
    return re.search(r"^-----BEGIN [A-Z ]*SIGNATURE-----$", body, re.M) is not None


def cut(dry_run):
    if output(["git", "status", "--porcelain"], "couldn't read the working tree"):
        raise ValueError("working tree is not clean; commit, stash or remove changes first")
    branch = output(["git", "symbolic-ref", "--quiet", "--short", "HEAD"], "HEAD is detached; check out the PR branch")
    output(["git", "fetch", "--quiet", "origin"], "git fetch origin failed")
    sha = output(["git", "rev-parse", "HEAD"], "couldn't resolve HEAD")
    pushed = output(["git", "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{branch}"])
    if pushed != sha:
        raise ValueError(f"HEAD {sha[:12]} is not pushed; origin/{branch} is {pushed[:12] or 'missing'}")
    values = dict(re.findall(r"^(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)\s*$",
                             Path("Glimmer/Version.xcconfig").read_text(), re.M))
    version, build = values["MARKETING_VERSION"], values["CURRENT_PROJECT_VERSION"]
    tags = {ref.removeprefix("refs/tags/"): target for ref, target in remote_refs("refs/tags/*").items()}
    if version in tags:
        raise ValueError(f"{version} already has a final tag; bump MARKETING_VERSION")
    pattern = re.compile(rf"{re.escape(version)}-rc\.([1-9][0-9]*)")
    numbers = {int(match[1]): name for name in tags if (match := pattern.fullmatch(name))}
    current = [number for number, name in numbers.items() if tags[name] == sha]
    if current:
        tag = numbers[max(current)]
        if runs := release_runs(sha):
            print(f"{tag} already identifies {sha} and has a Release run.")
            show(runs[0]["url"], dry_run)
            return
    else:
        tag = f"{version}-rc.{max(numbers, default=0) + 1}"
    local = output(["git", "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}^{{commit}}"])
    if local and local != sha:
        raise ValueError(f"tag {tag} already identifies {local[:12]}, not {sha[:12]}; tags are never replaced")
    print(f"Candidate {tag}: {version} build {build} at {sha} ({branch})")
    check_build(version, build)
    wait_for_checks(sha, dry_run)
    point_branch(sha, dry_run)
    if tag not in tags:
        if not local:
            step(dry_run, ["git", "tag", "-s", tag, sha, "-m", tag], "tag signing failed; refusing an unsigned tag")
        if not dry_run and not signed(tag):
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
            show(new[0]["url"], dry_run)
            return
        time.sleep(2)
    raise ValueError("dispatched, but the new Release run didn't appear; check the Actions tab")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="print every step without pushing, tagging or dispatching")
    args = parser.parse_args()
    os.chdir(SCRIPTS.parent)
    try:
        cut(args.dry_run)
    except (ValueError, KeyError, OSError, ET.ParseError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"ERR: {error}\n")


if __name__ == "__main__":
    main()
