# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Release acceptance history, not a claim that old passes tested the current commit."""

import argparse
from datetime import datetime, timezone
from fnmatch import fnmatchcase
from hashlib import sha256
import json
from pathlib import Path
import re
import subprocess


def definitions(root):
    cases = []
    shared = "".join(path.read_text() for path in sorted((root / "JourneySupport").glob("*.swift")))
    for platform, folder in (("mac", "GlimmerUITests"), ("ios", "iOS/GlimmerUITests")):
        fixture = root / folder / "TouchJourneyTestCase.swift"
        helpers = shared + (fixture.read_text() if fixture.exists() else "")
        for path in sorted((root / folder).glob("*Journey*.swift")):
            source = path.read_text()
            owner = re.search(r"\b(?:class|extension)\s+(\w+JourneyUITests)\b", source)
            if not owner:
                continue
            pattern = r"(?ms)^    func (test\w+)\([^)]*\)[^{]*\{(.*?)^    \}"
            methods = re.findall(pattern, source)
            local_helpers = "\n".join(line.rstrip() for line in re.sub(pattern, "", source).splitlines() if line.strip())
            for method, body in methods:
                identifier = f"{owner[1]}/{method}"
                digest = sha256((identifier + body + helpers + local_helpers).encode()).hexdigest()
                devices = ["mac"] if platform == "mac" else ["iphone", "ipad"]
                if owner[1] == "IPadTouchJourneyUITests":
                    devices = ["ipad"]
                for device in devices:
                    for theme in ("light", "dark"):
                        cases.append({"key": f"{device}/{theme}/{identifier}", "test": identifier,
                                      "device": device, "theme": theme, "definition": digest,
                                      "source": str(path.relative_to(root))})
    if len({case["key"] for case in cases}) != len(cases):
        raise ValueError("Duplicate acceptance case identifiers")
    return cases


def load(path, release):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", release):
        raise ValueError("Acceptance requires a release key, for example 2026.10.8")
    ledger = json.loads(path.read_text()) if path.exists() else {"version": 1, "release": release, "cases": {}}
    if ledger.get("version") != 1 or ledger.get("release") != release or not isinstance(ledger.get("cases"), dict):
        raise ValueError("Acceptance ledger has a different release or invalid schema")
    return ledger


def pending(ledger, cases, rerun=""):
    patterns = rerun.split()
    for pattern in patterns:
        if not any(fnmatchcase(case["key"], pattern) for case in cases):
            raise ValueError(f"Acceptance rerun selector matched no cases: {pattern}")
    selected = []
    for case in cases:
        entry = ledger["cases"].setdefault(case["key"], {"history": []})
        previous = entry["history"][-1] if entry["history"] else {}
        forced = any(fnmatchcase(case["key"], pattern) for pattern in patterns)
        status = previous.get("status", "pending") if previous.get("definition") == case["definition"] else "pending"
        if forced:
            status = "pending"
            entry["history"].append({"definition": case["definition"], "status": "pending", "sha": None,
                                     "source_note": "Affected-case rerun requested; previous pass retained as history",
                                     "recorded_at": datetime.now(timezone.utc).isoformat()})
        entry.update(case, status=status)
        if status != "passed":
            selected.append(case)
    ledger["active"] = [case["key"] for case in cases]
    return selected


def outcomes(document):
    results = {}
    def visit(node):
        if isinstance(node, list):
            for item in node:
                visit(item)
        elif isinstance(node, dict):
            if node.get("nodeType") == "Test Case":
                identifier = node.get("nodeIdentifier", "").removesuffix("()")
                if not re.fullmatch(r"\w+/test\w+", identifier):
                    raise ValueError("Unexpected acceptance test identifier")
                # A recovered retry is still a failed first pass.
                status = "passed" if node.get("result") == "Passed" else "failed"
                results[identifier] = "failed" if results.get(identifier) == "failed" else status
            visit(node.get("children", []))
    visit(document.get("testNodes", []))
    return results


def record(ledger, cases, results, sha, evidence, run, source_note=""):
    if sha is not None and not re.fullmatch(r"[a-f0-9]{40}", sha):
        raise ValueError("Acceptance evidence requires the actual full source SHA")
    if sha is None and not source_note.strip():
        raise ValueError("Working-tree evidence requires a source note, never an invented SHA")
    for case in cases:
        status = results.get(case["test"], "pending")
        entry = ledger["cases"][case["key"]]
        entry["status"] = status
        entry["history"].append({"sha": sha, "definition": case["definition"], "status": status,
                                 "evidence": evidence, "run": run, "source_note": source_note,
                                 "recorded_at": datetime.now(timezone.utc).isoformat()})


def save(ledger, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(ledger, indent=2) + "\n")
    temporary.replace(path)


def summary(ledger):
    lines = [f"### Release acceptance: {ledger['release']}", "",
             "Historical acceptance evidence; each pass retains its tested SHA. The release owner selects affected reruns.", "",
             "| Case / device / theme | Status | Tested SHA |", "| --- | --- | --- |"]
    for key in ledger.get("active", []):
        entry = ledger["cases"][key]
        last = entry["history"][-1] if entry["history"] else {}
        provenance = last.get("sha") or last.get("source_note") or "not run"
        lines.append(f"| {key} | {entry['status']} | {provenance.replace('|', '/').replace(chr(10), ' ')} |")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Import existing XCTest acceptance evidence without running tests")
    parser.add_argument("--release", required=True)
    parser.add_argument("--ledger", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--result", type=Path)
    source.add_argument("--tests-json", type=Path)
    parser.add_argument("--device", choices=("mac", "iphone", "ipad"), required=True)
    parser.add_argument("--theme", choices=("light", "dark"), required=True)
    parser.add_argument("--sha")
    parser.add_argument("--source-note", default="")
    parser.add_argument("--reviewed-current-definitions", action="store_true",
                        help="Owner reviewed that these results exercised the current test definitions")
    args = parser.parse_args()
    document = json.loads(args.tests_json.read_text() if args.tests_json else subprocess.check_output(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(args.result)], text=True, timeout=60))
    results = outcomes(document)
    ledger = load(args.ledger, args.release)
    cases = definitions(args.source_root)
    pending(ledger, cases)
    selected = [dict(case) for case in cases if case["device"] == args.device and case["theme"] == args.theme
                and case["test"] in results]
    if not selected:
        raise ValueError("Imported evidence matches no current acceptance cases")
    if not args.reviewed_current_definitions:
        for case in selected:
            case["definition"] = None
    record(ledger, selected, results, args.sha, "local evidence retained privately", "local import", args.source_note)
    pending(ledger, cases)
    save(ledger, args.ledger)
    print(summary(ledger))


if __name__ == "__main__":
    main()
