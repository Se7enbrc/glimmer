# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""A successful partial Swift analysis must not satisfy the CodeQL gate."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

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


if __name__ == "__main__":
    unittest.main()
