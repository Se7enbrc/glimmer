"""Coverage summaries must never turn a missing denominator into a percentage."""

import importlib.util
from pathlib import Path
import unittest

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


if __name__ == "__main__":
    unittest.main()
