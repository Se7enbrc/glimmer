#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Summarize one coverage run per component; measure only, never gate."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

OUT = Path("build/coverage")
DEBUG = Path("build/Build/Products/Debug")
APP = DEBUG / "Glimmer.app/Contents/MacOS/Glimmer.debug.dylib"
TESTS = DEBUG / "Glimmer.app/Contents/PlugIns/GlimmerTests.xctest/Contents/MacOS/GlimmerTests"
HEADER = "| Component | Lines (xccov) | Lines (llvm-cov) | Regions | Branches |\n| --- | --- | --- | --- | --- |\n"


def pct(covered, total):
    return f"{100 * covered / total:.2f}% ({covered}/{total})" if total else "not measured (0 counted)"


def xccov_lines(report, target, part=""):
    files = [f for t in report["targets"] if t["name"] == target for f in t["files"] if part in f["path"]]
    return pct(sum(f["coveredLines"] for f in files), sum(f["executableLines"] for f in files))


def llvm_row(totals):
    return " | ".join(pct(totals[key]["covered"], totals[key]["count"]) for key in ("lines", "regions", "branches"))


def llvm_totals(binary, profile, name, *sources):
    # Generated asset symbols are build output, not project source.
    data = subprocess.run(["xcrun", "llvm-cov", "export", "-summary-only", f"-instr-profile={profile}",
                           "-ignore-filename-regex=/DerivedSources/", str(binary), *sources],
                          check=True, capture_output=True, text=True).stdout
    (OUT / "swift" / name).write_text(data)
    return json.loads(data)["data"][0]["totals"]


def swift():
    profiles = list(Path("build/Build/ProfileData").glob("*/Coverage.profdata"))
    if len(profiles) != 1:
        sys.exit(f"ERROR: expected one profile from this run, found {len(profiles)}")
    data = subprocess.run(["xcrun", "xccov", "view", "--report", "--json", str(OUT / "swift/glimmer.xcresult")],
                          check=True, capture_output=True, text=True).stdout
    (OUT / "swift/xccov.json").write_text(data)
    report = json.loads(data)
    app = llvm_totals(APP, profiles[0], "llvm-app.json")
    helper = llvm_totals(TESTS, profiles[0], "llvm-helper.json", "helper/")
    return ("## Swift coverage\n\n" + HEADER
            + f"| App (`Glimmer.debug.dylib`) | {xccov_lines(report, 'Glimmer.app')} | {llvm_row(app)} |\n"
            + f"| Helper sources in the test bundle | {xccov_lines(report, 'GlimmerTests.xctest', '/helper/')}"
            + f" | {llvm_row(helper)} |\n"
            + f"| Login item | {xccov_lines(report, 'Glimmer Login Helper.app')} | not executed | - | - |\n\n"
            + "The login item never runs under test. The installed helper daemon is compiled separately by swiftc"
            + " and never runs under test; only its sources linked into the test bundle are measured, without"
            + " `helper/main.swift`. Swift emits no branch counters (swiftlang/swift#81730).\n")


def python():
    tool = shlex.split(os.environ.get("COVERAGE_PY", "python3 -m coverage"))
    rc = "--rcfile=scripts/tests/coveragerc"
    subprocess.run([*tool, "combine", rc], check=True, capture_output=True)
    report = subprocess.run([*tool, "report", rc], check=True, capture_output=True, text=True).stdout
    (OUT / "python/report.txt").write_text(report)
    subprocess.run([*tool, "json", rc, "-o", str(OUT / "python/coverage.json")], check=True, capture_output=True)
    totals = json.loads((OUT / "python/coverage.json").read_text())["totals"]
    return ("## Python release tooling coverage\n\n| Statements | Branches |\n| --- | --- |\n"
            + f"| {pct(totals['covered_lines'], totals['num_statements'])}"
            + f" | {pct(totals['covered_branches'], totals['num_branches'])} |\n\n"
            + "Shell scripts and Python run as a subprocess from a fixture copy are exercised but not measured.\n")


if __name__ == "__main__":
    part = sys.argv[1] if len(sys.argv) == 2 else ""
    if part not in ("swift", "python"):
        sys.exit("usage: coverage-report.py swift|python")
    summary = swift() if part == "swift" else python()
    (OUT / part / "summary.md").write_text(summary)
    print(summary)
