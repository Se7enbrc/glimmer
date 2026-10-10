# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""A successful partial Swift analysis must not satisfy the CodeQL gate."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location("codeql_coverage", Path(__file__).parents[1] / "codeql-coverage.py")
COVERAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COVERAGE)
EXPECTED = {"Glimmer/GlimmerApp.swift", "LoginHelper/main.swift", "helper/main.swift"}


class CodeQLCoverageTests(unittest.TestCase):
    def test_complete_extraction_allows_dependencies_and_duplicate_paths(self):
        output = "\n".join(f'"{path}"' for path in sorted(EXPECTED))
        self.assertEqual(COVERAGE.validate_coverage(EXPECTED, output + '\n"build/dependency.swift"\n'
                                                  '"helper/main.swift"\n'), 3)

    def test_empty_or_helper_only_extraction_fails(self):
        for output in ("", '"helper/main.swift"\n'):
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, "did not successfully extract"):
                COVERAGE.validate_coverage(EXPECTED, output)

    def test_one_missing_app_source_cannot_hide_behind_all_three_targets(self):
        output = "\n".join(EXPECTED)
        with self.assertRaisesRegex(ValueError, "Glimmer/Stream/Pairing.swift"):
            COVERAGE.validate_coverage(EXPECTED | {"Glimmer/Stream/Pairing.swift"}, output)

    def test_missing_expected_target_and_malformed_output_fail(self):
        with self.assertRaisesRegex(ValueError, "both helpers"):
            COVERAGE.validate_coverage({"Glimmer/GlimmerApp.swift"}, "Glimmer/GlimmerApp.swift")
        with self.assertRaisesRegex(ValueError, "invalid"):
            COVERAGE.validate_coverage(EXPECTED, "Glimmer/GlimmerApp.swift,extra")

    def test_query_uses_successful_extraction_and_bundled_swift_library(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "database"
            database.mkdir()
            (database / "codeql-database.yml").touch()
            (root / "codeql").touch()
            (root / "qlpacks").mkdir()
            commands = []

            def command(arguments, cwd):
                commands.append(arguments)
                self.assertEqual((cwd / "coverage.ql").read_text(), COVERAGE.QUERY)
                self.assertIn("codeql/swift-all", (cwd / "qlpack.yml").read_text())
                if "decode" in arguments:
                    return "\n".join(EXPECTED)
                self.assertIn(f"--additional-packs={root / 'qlpacks'}", arguments)
                return ""

            with patch.object(COVERAGE, "tracked_sources", return_value=EXPECTED), \
                    patch.object(COVERAGE, "codeql_command", side_effect=command):
                self.assertEqual(COVERAGE.check(root, database, root), 3)
            self.assertIn("file.isSuccessfullyExtracted()", COVERAGE.QUERY)
            self.assertEqual([command[1:3] for command in commands],
                             [["pack", "install"], ["query", "run"], ["bqrs", "decode"]])
            self.assertIn(f"--database={database}", commands[1])

    def test_query_failure_blocks_without_returning_empty_success(self):
        for failure in (subprocess.CalledProcessError(2, "codeql"),
                        subprocess.TimeoutExpired("codeql", 300), FileNotFoundError()):
            with self.subTest(failure=failure), patch.object(COVERAGE.subprocess, "run", side_effect=failure):
                with self.assertRaisesRegex(ValueError, "compiler's CodeQL support"):
                    COVERAGE.codeql_command(["codeql"], Path.cwd())

    def test_tracked_sources_lists_only_tracked_swift_under_production_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True, env=env)
            for name in ("Glimmer/A.swift", "Glimmer/note.md", "helper/main.swift", "Other/B.swift",
                         "Glimmer/with space.swift"):
                (repo / name).parent.mkdir(exist_ok=True)
                (repo / name).write_text("x")
            (repo / "Glimmer/untracked.swift").write_text("x")
            subprocess.run(["git", "add", "Glimmer/A.swift", "Glimmer/note.md", "helper/main.swift",
                            "Other/B.swift", "Glimmer/with space.swift"], cwd=repo, check=True, env=env)
            with patch.dict(os.environ, env, clear=True):
                self.assertEqual(COVERAGE.tracked_sources(repo),
                                 {"Glimmer/A.swift", "helper/main.swift", "Glimmer/with space.swift"})

    def test_check_requires_a_finalized_database_and_an_initialized_distribution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, "database is missing"):
                COVERAGE.check(root, root / "db", root)
            (root / "db").mkdir()
            (root / "db/codeql-database.yml").touch()
            with patch.object(COVERAGE, "tracked_sources") as tracked, \
                    self.assertRaisesRegex(ValueError, "distribution and bundled query packs"):
                COVERAGE.check(root, root / "db", root)
            tracked.assert_not_called()
            (root / "codeql").touch()
            with self.assertRaisesRegex(ValueError, "distribution and bundled query packs"):
                COVERAGE.check(root, root / "db", root)

    def run_main(self, env, check):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(sys, "argv", ["x", "--database", "db"]), patch.dict(os.environ, env, clear=True), \
                patch.object(COVERAGE, "check", check), contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(err):
            try:
                code = COVERAGE.main()
            except SystemExit as exit_:
                code = exit_.code
        return code, out.getvalue(), err.getvalue()

    def test_main_needs_codeql_dist_and_turns_failures_into_exit_one(self):
        check = Mock(return_value=3)
        code, _, err = self.run_main({}, check)
        self.assertEqual(code, 2)
        self.assertIn("CODEQL_DIST must come from CodeQL initialization", err)
        check.assert_not_called()
        code, out, _ = self.run_main({"CODEQL_DIST": "/dist"}, check)
        self.assertEqual((code, out), (0, "CodeQL successfully extracted all 3 tracked production Swift files\n"))
        for failure in (ValueError("gap"), OSError("io"), subprocess.CalledProcessError(1, "git")):
            code, out, err = self.run_main({"CODEQL_DIST": "/dist"}, Mock(side_effect=failure))
            self.assertEqual((code, out), (1, ""))
            self.assertIn("Swift CodeQL coverage failed", err)


if __name__ == "__main__":
    unittest.main()
