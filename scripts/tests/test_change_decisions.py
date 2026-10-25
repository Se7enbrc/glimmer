# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Run the workflow decision shells with inert API responses and broken classifiers."""

import os
from pathlib import Path
import shutil
import sys
import tempfile
import textwrap
import unittest

from fixture_git import FixtureTestCase

from fixture_process import run_fixture

ROOT = Path(__file__).resolve().parents[2]


class ChangeDecisionTests(FixtureTestCase):
    def decision(self, workflow, paths, classifier=None, api_status="0"):
        verify = workflow == "verify"
        script = "verify-changed.py" if verify else "codeql-swift-changed.py"
        key = "build" if verify else "scan"
        source = (ROOT / f".github/workflows/{workflow}.yml").read_text()
        start = source.index(f"          {key}=true")
        end = source.index('>> "$GITHUB_OUTPUT"', start) + len('>> "$GITHUB_OUTPUT"')
        shell = textwrap.dedent(source[start:end])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            target = root / "scripts" / script
            if classifier is None:
                shutil.copy2(ROOT / "scripts" / script, target)
            elif classifier != "missing":
                target.write_text(classifier)
            (root / "python3").symlink_to(sys.executable)
            gh = root / "gh"
            gh.write_text('#!/bin/bash\nprintf "%s" "$FIXTURE_PATHS"\nexit "$FIXTURE_API_STATUS"\n')
            gh.chmod(0o755)
            output = root / "output"
            env = {**os.environ, "PATH": f"{root}:/usr/bin:/bin", "PR_NUMBER": "1", "LANGUAGE": "swift",
                   "GITHUB_REPOSITORY": "fixture/repo", "GITHUB_OUTPUT": str(output),
                   "FIXTURE_PATHS": paths, "FIXTURE_API_STATUS": api_status}
            result = run_fixture(["/bin/bash", "-euo", "pipefail", "-c", shell], cwd=root, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            return dict(line.split("=", 1) for line in output.read_text().splitlines())[key]

    def test_only_successful_explicit_skip_can_omit_work(self):
        cases = [
            ("docs/README.md\n", None, "0", "false"),
            ("Glimmer/AppModel.swift\n", None, "0", "true"),
            ("", None, "0", "true"),
            (" \n", None, "0", "true"),
            ("docs/README.md\n", "missing", "0", "true"),
            ("docs/README.md\n", 'raise RuntimeError("fixture")\n', "0", "true"),
            ("docs/README.md\n", 'print("skip"); raise RuntimeError("fixture")\n', "0", "true"),
            ("docs/README.md\n", "", "0", "true"),
            ("docs/README.md\n", 'print("unknown")\n', "0", "true"),
            ("docs/README.md\n", None, "1", "true"),
            ("docs/README.md\n" * 3000, None, "0", "true"),
        ]
        for workflow in ("verify", "codeql"):
            for paths, classifier, status, expected in cases:
                with self.subTest(workflow=workflow, classifier=classifier, status=status, count=len(paths)):
                    self.assertEqual(self.decision(workflow, paths, classifier, status), expected)
