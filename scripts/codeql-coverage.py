#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Require successful Swift extraction for every tracked production source."""

import argparse
import csv
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile

QUERY = """import swift
from File file
where file.isSuccessfullyExtracted()
select file.getRelativePath()
"""
PACK = """name: glimmer/coverage
version: 0.0.0
dependencies:
  codeql/swift-all: '*'
"""
ROOTS = ("Glimmer", "LoginHelper", "helper")


def tracked_sources(repo):
    result = subprocess.run(["git", "ls-files", "-z", "--", *ROOTS], cwd=repo,
                            capture_output=True, check=True)
    return {path for path in result.stdout.decode().split("\0") if path.endswith(".swift")}


def validate_coverage(expected, output):
    if not expected or any(not any(path.startswith(root + "/") for path in expected) for root in ROOTS):
        raise ValueError("The tracked Swift source list must include the app and both helpers")
    rows = list(csv.reader(io.StringIO(output)))
    if any(len(row) != 1 or not row[0] for row in rows):
        raise ValueError("CodeQL returned an invalid extracted-file list")
    extracted = {row[0] for row in rows}
    missing = sorted(expected - extracted)
    if missing:
        raise ValueError(f"CodeQL did not successfully extract {len(missing)} production Swift file(s): "
                         + ", ".join(missing))
    return len(expected)


def codeql_command(arguments, cwd):
    try:
        return subprocess.run(arguments, cwd=cwd, check=True, capture_output=True,
                              text=True, timeout=300).stdout
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise ValueError("CodeQL coverage query failed. Check the installed Swift compiler's CodeQL "
                         "support and bundled codeql/swift-all pack availability") from error


def check(repo, database, distribution):
    if not (database / "codeql-database.yml").is_file():
        raise ValueError("The finalized Swift CodeQL database is missing")
    codeql = distribution / "codeql"
    packs = distribution / "qlpacks"
    if not codeql.is_file() or not packs.is_dir():
        raise ValueError("The initialized CodeQL distribution and bundled query packs are required")
    expected = tracked_sources(repo)
    with tempfile.TemporaryDirectory(prefix="glimmer-codeql-coverage-") as directory:
        work = Path(directory)
        (work / "qlpack.yml").write_text(PACK)
        query = work / "coverage.ql"
        query.write_text(QUERY)
        additional = f"--additional-packs={packs}"
        codeql_command([str(codeql), "pack", "install", additional], work)
        result = work / "coverage.bqrs"
        codeql_command([str(codeql), "query", "run", additional, f"--database={database}",
                        f"--output={result}", "--warnings=error", str(query)], work)
        output = codeql_command([str(codeql), "bqrs", "decode", "--format=csv", "--no-titles",
                                 str(result)], work)
        return validate_coverage(expected, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    arguments = parser.parse_args()
    distribution = os.environ.get("CODEQL_DIST")
    if not distribution:
        parser.error("CODEQL_DIST must come from CodeQL initialization")
    try:
        count = check(arguments.repo.resolve(), arguments.database.resolve(), Path(distribution).resolve())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Swift CodeQL coverage failed: {error}", file=sys.stderr)
        return 1
    print(f"CodeQL successfully extracted all {count} tracked production Swift files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
