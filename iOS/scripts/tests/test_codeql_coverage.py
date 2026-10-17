# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Partial extraction must not satisfy the iOS Swift analysis gate."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("codeql_coverage", Path(__file__).parents[1] / "codeql-coverage.py")
COVERAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COVERAGE)
EXPECTED = {"Glimmer/GlimmerApp.swift", "Glimmer/LauncherServices.swift"}


class CodeQLCoverageTests(unittest.TestCase):
    def test_complete_app_with_dependencies_and_duplicates_passes(self):
        output = "\n".join(EXPECTED) + "\nDependency/Engine.swift\nGlimmer/GlimmerApp.swift\n"
        self.assertEqual(COVERAGE.validate_coverage(EXPECTED, output), 2)

    def test_missing_app_file_or_dependency_only_analysis_fails(self):
        for output in ("", "Dependency/Engine.swift", "Glimmer/GlimmerApp.swift"):
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, "did not successfully extract"):
                COVERAGE.validate_coverage(EXPECTED, output)

    def test_empty_expectations_and_malformed_query_output_fail(self):
        for expected in (set(), {"GlimmerTests/Test.swift"}):
            with self.subTest(expected=expected), self.assertRaisesRegex(ValueError, "include the iOS app"):
                COVERAGE.validate_coverage(expected, "")
        for output in ("Glimmer/A.swift,extra", '""'):
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, "invalid"):
                COVERAGE.validate_coverage(EXPECTED, output)

    def test_tracked_sources_excludes_tests_dependencies_and_untracked_files(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True, env=env)
            paths = ("Glimmer/A.swift", "Glimmer/with space.swift", "Glimmer/note.md",
                     "GlimmerTests/Test.swift", "build/Engine.swift")
            for name in paths:
                (repo / name).parent.mkdir(exist_ok=True)
                (repo / name).write_text("x")
            (repo / "Glimmer/Untracked.swift").write_text("x")
            subprocess.run(["git", "add", "--", *paths], cwd=repo, check=True, env=env)
            with patch.dict(os.environ, env, clear=True):
                self.assertEqual(COVERAGE.tracked_sources(repo), {"Glimmer/A.swift", "Glimmer/with space.swift"})

    def test_check_requires_finalized_database_and_distribution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, "database is missing"):
                COVERAGE.check(root, root, root)
            (root / "codeql-database.yml").touch()
            with self.assertRaisesRegex(ValueError, "distribution and bundled query packs"):
                COVERAGE.check(root, root, root)

    def test_successful_extraction_query_is_decoded_and_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "codeql-database.yml").touch()
            (root / "codeql").touch()
            (root / "qlpacks").mkdir()
            commands = []

            def command(arguments, cwd):
                commands.append(arguments)
                self.assertIn("file.isSuccessfullyExtracted()", (cwd / "coverage.ql").read_text())
                return "\n".join(EXPECTED) if "decode" in arguments else ""

            with patch.object(COVERAGE, "tracked_sources", return_value=EXPECTED), \
                    patch.object(COVERAGE, "codeql_command", side_effect=command):
                self.assertEqual(COVERAGE.check(root, root, root), 2)
            self.assertEqual([cmd[1:3] for cmd in commands],
                             [["pack", "install"], ["query", "run"], ["bqrs", "decode"]])

    def test_failed_or_timed_out_query_cannot_pass(self):
        for error in (FileNotFoundError(), subprocess.CalledProcessError(1, "codeql"),
                      subprocess.TimeoutExpired("codeql", 300)):
            with self.subTest(error=error), patch.object(COVERAGE.subprocess, "run", side_effect=error), \
                    self.assertRaisesRegex(ValueError, "query failed"):
                COVERAGE.codeql_command(["codeql"], Path.cwd())


if __name__ == "__main__":
    unittest.main()
