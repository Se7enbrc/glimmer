#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Select Verify jobs for the tested revision and validate their actual outcomes."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys

DOCS_ONLY = re.compile(
    r"\.md$|^docs/|^website/|^index\.html$|^\.github/ISSUE_TEMPLATE/|^LICENSE$"
)
VERSION = "Glimmer/Version.xcconfig"
VERSION_VALUES = re.compile(
    r"^(MARKETING_VERSION = )[0-9]+\.[0-9]+\.[0-9]+$|^(CURRENT_PROJECT_VERSION = )[1-9][0-9]*$", re.M
)


def version_metadata_only(base):
    if not base or not re.fullmatch(r"[0-9a-f]{40}", base):
        return False
    try:
        configs = [subprocess.check_output(["git", "show", f"{ref}:{VERSION}"],
                                          text=True, stderr=subprocess.DEVNULL, timeout=10)
                   for ref in (base, "HEAD")]
    except (OSError, subprocess.SubprocessError):
        return False
    keys = [[first or second for first, second in VERSION_VALUES.findall(config)] for config in configs]
    expected = ["MARKETING_VERSION = ", "CURRENT_PROJECT_VERSION = "]
    return (all(sorted(found) == sorted(expected) for found in keys)
            and VERSION_VALUES.sub(lambda match: match[1] or match[2], configs[0])
            == VERSION_VALUES.sub(lambda match: match[1] or match[2], configs[1]))


def must_build(paths, base=None):
    # An empty or unreadable list builds: skipping is the only outcome that needs proof.
    paths = [path.strip() for path in paths if path.strip()]
    if not paths:
        return True
    code = [path for path in paths if not DOCS_ONLY.search(path)]
    return bool(code) and (set(code) != {VERSION} or not version_metadata_only(base))


ROOT = Path(__file__).resolve().parents[1]
APPLE_LAYOUT = ("Package.swift", "GlimmerEngine", "iOS/Makefile")
FULL = {"native", "mac", "package", "device", "ios", "fuzz"}
JOB_TASKS = {
    "checks": {"portable"},
    "verify": {"native"},
    "mac-core": {"desktop"},
    "sequoia": {"compat"},
    "apple-builds": {"package", "device"},
    "ios-core": {"ios"},
    "fuzz": {"fuzz"},
}


def pr_tasks(paths, base, ios_project, mac_project):
    paths = list(paths)
    if not must_build(paths, base):
        return set()
    if not paths:
        return FULL.copy()
    tasks = {"native"}
    for path in paths:
        if DOCS_ONLY.search(path):
            continue
        if path.startswith(("Glimmer/", "GlimmerTests/", "helper/", "LoginHelper/")) and path.endswith(".swift"):
            tasks.add("mac")
            # iOS compiles selected sources and fixtures from the Mac tree.
            if Path(path).name in ios_project or "PBXFileSystemSynchronizedRootGroup" in ios_project:
                tasks.add("ios")
                if not path.startswith("GlimmerTests/"):
                    tasks.add("device")
        elif path.startswith("iOS/"):
            tasks.add("ios")
            if not path.startswith(("iOS/GlimmerTests/", "iOS/GlimmerUITests/")):
                tasks.add("device")
            if "iOS/" in mac_project or "path = iOS;" in mac_project:
                tasks.add("mac")
        elif path.startswith("scripts/tests/") or path in {"renovate.json", ".markdownlint.json", ".prettierignore"}:
            # The portable and native tooling suites exercise these inputs.
            continue
        elif path.startswith("fuzz/") or path == "scripts/fuzz.sh":
            tasks.add("fuzz")
        else:
            # Shared engine, toolchain, project membership or an unknown input.
            return FULL.copy()
    return tasks


def changed_paths(base):
    # On pull_request checkout, HEAD is the merge result and its first parent
    # is the base tested by GitHub. Compare those exact trees, including deletions.
    if not re.fullmatch(r"[0-9a-f]{40}", base or ""):
        return []
    try:
        if subprocess.check_output(["git", "rev-parse", "HEAD^1"], text=True).strip() != base:
            return []
        raw = subprocess.check_output(["git", "diff", "--name-only", "--no-renames", "-z", base, "HEAD", "--"])
    except subprocess.CalledProcessError:
        return []
    return [os.fsdecode(name) for name in raw.split(b"\0") if name]


def plan(event, base, ref):
    layout = [(ROOT / path).exists() for path in APPLE_LAYOUT]
    if any(layout) and not all(layout):
        raise ValueError("Incomplete Apple project layout")
    apple = all(layout)
    tasks = FULL.copy()
    if event == "pull_request":
        paths = changed_paths(base)
        ios_project = (ROOT / "iOS/Glimmer.xcodeproj/project.pbxproj").read_text() if apple else ""
        mac_project = (ROOT / "Glimmer.xcodeproj/project.pbxproj").read_text()
        tasks = pr_tasks(paths, base, ios_project, mac_project)
    elif ref in {"main", "release-candidate"}:
        tasks.update(("desktop", "compat"))
    if not apple:
        tasks.difference_update(("ios", "device", "package", "compat"))
    tasks.add("portable")
    return tasks


def require_results(jobs, needs):
    eligible = set(JOB_TASKS)
    if not isinstance(jobs, list) or "checks" not in jobs or not set(jobs) <= eligible:
        raise ValueError("Missing or invalid verification plan")
    if set(needs) != eligible | {"changes"}:
        raise ValueError("Required gate dependencies differ from the verification jobs")
    for job, info in needs.items():
        expected = "success" if job == "changes" or job in jobs else "skipped"
        if info["result"] != expected:
            raise ValueError(f"{job}: expected {expected}, got {info['result']}")


if __name__ == "__main__":
    if sys.argv[1:] == ["--plan"]:
        tasks = plan(os.environ["GITHUB_EVENT_NAME"], os.environ.get("PR_BASE_SHA"), os.environ["GITHUB_REF_NAME"])
        jobs = sorted(name for name, required in JOB_TASKS.items() if required & tasks)
        print("jobs=" + json.dumps(jobs))
        print("tasks=" + json.dumps(sorted(tasks)))
    elif sys.argv[1:] == ["--gate"]:
        require_results(json.loads(os.environ["PLAN"]), json.loads(os.environ["NEEDS"]))
    else:
        print("run" if must_build(sys.stdin, base=os.environ.get("PR_BASE_SHA")) else "skip")
