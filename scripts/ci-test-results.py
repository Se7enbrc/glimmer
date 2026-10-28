#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Summarize XCTest failures and successful retries without hiding the first attempt."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlsplit, parse_qs


def failures(value):
    """Read legacy xcresult issues, including Swift Testing's source locations."""
    found = []
    if isinstance(value, dict):
        if "message" in value and ("testCaseName" in value or "documentLocationInCreatingWorkspace" in value):
            def scalar(item):
                return item.get("_value", "") if isinstance(item, dict) else str(item)
            location = value.get("documentLocationInCreatingWorkspace", {}).get("url", {})
            found.append((scalar(value.get("testCaseName", "Build")), scalar(value["message"]), scalar(location)))
        for item in value.values():
            found.extend(failures(item))
    elif isinstance(value, list):
        for item in value:
            found.extend(failures(item))
    return list(dict.fromkeys(found))


def log_attempts(log):
    attempts = {}
    for name, outcome in re.findall(r"Test Case '([^']+)' (passed|failed)", log):
        attempts.setdefault(name, []).append(outcome)
    return attempts


def render(shard, result, log, status):
    issues = []
    if result.exists():
        command = ["xcrun", "xcresulttool", "get", "object", "--legacy", "--format", "json", "--path", str(result)]
        try:
            output = subprocess.run(command, capture_output=True, text=True, timeout=60, check=True)
            issues = failures(json.loads(output.stdout))
        except (subprocess.SubprocessError, ValueError) as error:
            issues = [("Result summary unavailable", type(error).__name__, str(result))]
    lines = [f"### {shard}: {'passed' if status == 0 else 'failed'}", ""]
    if issues:
        lines += ["Failures (including recovered attempts):", ""]
        for name, message, location in issues:
            if location.startswith("file://"):
                parsed = urlsplit(location)
                line = parse_qs(parsed.fragment).get("StartingLineNumber", [""])[0]
                location = unquote(parsed.path) + (f":{line}" if line else "")
            lines.append(f"- **{name}**: {message} {location}".rstrip())
        lines.append("")
    retries = [name for name, outcomes in log_attempts(log).items() if "failed" in outcomes and outcomes[-1] == "passed"]
    if retries:
        lines += ["Recovered on an in-job retry; investigate these flakes:", ""]
        lines += [f"- {name}" for name in retries]
        lines.append("")
    if status and not issues:
        lines += ["No readable test failure receipt; inspect the attached build/test log (including startup errors).", ""]
    lines += [f"Reproduce: `make ci-local SHARD={shard}`", f"Result bundle: `{result}`", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("shard")
    parser.add_argument("result", type=Path)
    parser.add_argument("log", type=Path)
    parser.add_argument("status", type=int)
    parser.add_argument("--coverage", type=Path)
    args = parser.parse_args()
    summary = render(args.shard, args.result, args.log.read_text(errors="replace") if args.log.exists() else "", args.status)
    if args.coverage and args.coverage.exists():
        summary += "\nCoverage:\n\n```text\n" + args.coverage.read_text() + "\n```\n"
    args.log.with_suffix(".md").write_text(summary)
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as output:
            output.write(summary)


if __name__ == "__main__":
    main()
