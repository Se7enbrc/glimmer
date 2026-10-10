"""Coverage summaries must never turn a missing denominator into a percentage."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("coverage_report", Path(__file__).parents[1] / "coverage-report.py")
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


class CoverageReportTests(unittest.TestCase):
    def test_zero_denominator_is_not_measured(self):
        self.assertEqual(REPORT.pct(0, 0), "not measured (0 counted)")
        self.assertEqual(REPORT.pct(1, 3), "33.33% (1/3)")

    def test_component_lines_filter_target_and_path(self):
        report = {"targets": [
            {"name": "GlimmerTests.xctest", "files": [
                {"path": "/r/helper/HelperService.swift", "executableLines": 4, "coveredLines": 3},
                {"path": "/r/GlimmerTests/HelperTests.swift", "executableLines": 9, "coveredLines": 9}]},
            {"name": "Glimmer.app", "files": [{"path": "/r/helper/Protocol.swift", "executableLines": 5,
                                               "coveredLines": 0}]}]}
        self.assertEqual(REPORT.xccov_lines(report, "GlimmerTests.xctest", "/helper/"), "75.00% (3/4)")
        self.assertEqual(REPORT.xccov_lines(report, "Glimmer Login Helper.app"), "not measured (0 counted)")

    def test_llvm_row_reports_missing_branch_counters(self):
        totals = {"lines": {"covered": 1, "count": 2}, "regions": {"covered": 2, "count": 4},
                  "branches": {"covered": 0, "count": 0}}
        self.assertEqual(REPORT.llvm_row(totals), "50.00% (1/2) | 50.00% (2/4) | not measured (0 counted)")


class ReportModeTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        for part in ("swift", "python"):
            (self.root / "out" / part).mkdir(parents=True)
        patcher = patch.object(REPORT, "OUT", self.root / "out")
        patcher.start()
        self.addCleanup(patcher.stop)
        previous = os.getcwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous)

    def test_python_report_combines_then_reports_totals_without_gating(self):
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            if "json" in command:
                (self.root / "out/python/coverage.json").write_text(json.dumps({"totals": {
                    "covered_lines": 3, "num_statements": 4, "covered_branches": 0, "num_branches": 0}}))
            return subprocess.CompletedProcess(command, 0, stdout="table", stderr="")

        with patch.dict(os.environ, {"COVERAGE_PY": "py -m coverage"}), patch.object(REPORT.subprocess, "run", side_effect=run):
            summary = REPORT.python()
        self.assertEqual([c[3] for c in calls], ["combine", "report", "json"])
        self.assertEqual(calls[0][:3], ["py", "-m", "coverage"])
        self.assertIn("| 75.00% (3/4) | not measured (0 counted) |", summary)
        self.assertEqual((self.root / "out/python/report.txt").read_text(), "table")

    def test_swift_report_refuses_without_exactly_one_profile(self):
        for count in (0, 2):
            for index in range(count):
                profile = self.root / f"build/Build/ProfileData/{index}/Coverage.profdata"
                profile.parent.mkdir(parents=True)
                profile.touch()
            with self.subTest(count=count), self.assertRaisesRegex(SystemExit, f"found {count}"):
                REPORT.swift()

    def test_swift_report_fills_app_helper_and_login_rows(self):
        profile = self.root / "build/Build/ProfileData/a/Coverage.profdata"
        profile.parent.mkdir(parents=True)
        profile.touch()
        totals = {"data": [{"totals": {key: {"covered": 1, "count": 2} for key in ("lines", "regions", "branches")}}]}
        xccov = {"targets": [{"name": "Glimmer.app", "files": [{"path": "/r/A.swift", "executableLines": 10,
                                                                 "coveredLines": 5}]}]}

        def run(command, **kwargs):
            body = json.dumps(xccov if command[1] == "xccov" else totals)
            return subprocess.CompletedProcess(command, 0, stdout=body, stderr="")

        with patch.object(REPORT.subprocess, "run", side_effect=run) as called:
            summary = REPORT.swift()
        self.assertIn("| App (`Glimmer.debug.dylib`) | 50.00% (5/10) | 50.00% (1/2)", summary)
        self.assertIn("| Login item | not measured (0 counted) | not executed", summary)
        self.assertTrue(any("-ignore-filename-regex=/DerivedSources/" in c for c in (x.args[0] for x in called.call_args_list)))
        self.assertTrue((self.root / "out/swift/llvm-helper.json").exists())

    def test_unknown_or_missing_mode_prints_usage_and_exits_nonzero(self):
        for argv in ([], ["bogus"], ["swift", "python"]):
            result = subprocess.run([sys.executable, REPORT.__file__, *argv], capture_output=True, text=True)
            with self.subTest(argv=argv):
                self.assertEqual(result.returncode, 1)
                self.assertIn("usage: coverage-report.py swift|python", result.stderr)


if __name__ == "__main__":
    unittest.main()
