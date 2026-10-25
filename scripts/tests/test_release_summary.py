# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Summaries distinguish missing, draft and public releases with safe retry guidance."""

import os
from pathlib import Path
import sys
import unittest

from fixture_git import FixtureTestCase
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
from release_summary import duration, report


class ReleaseSummaryTests(FixtureTestCase):
    def test_summary_reports_identity_durations_hashes_and_recovery_without_diagnostics(self):
        jobs = [{'name': 'publication / publish', 'conclusion': 'failure',
                 'started_at': '2026-10-12T12:00:00Z', 'completed_at': '2026-10-12T12:00:12Z',
                 'steps': [{'name': 'Upload', 'conclusion': 'failure',
                            'started_at': '2026-10-12T12:00:01Z', 'completed_at': '2026-10-12T12:00:11Z',
                            'raw_diagnostic': 'fixture-secret-not-for-summary'}]}]
        with patch.dict(os.environ, EXPECTED_SHA='a' * 40, RC_TAG='2026.10.6-rc.1',
                        GITHUB_RUN_ID='12', GITHUB_RUN_ATTEMPT='2'):
            text = report(jobs, {'draft': False, 'prerelease': True}, {'release.zip': 'b' * 64}, '400')
            for value in ('a' * 40, '2026.10.6-rc.1', '400', '12s', '10s', 'b' * 64,
                          'candidate is public', 'Feed or tap may still need repair',
                          'Never rerun build or signing', 'Pages deployment', 'Public appcast',
                          'earlier attempts of this run remain valid', 'tooling left main history'):
                self.assertIn(value, text)
            self.assertNotIn('fixture-secret', text)
            self.assertIn('Nothing published', report([], {}, {}, '400'))
            self.assertIn('draft exists', report([], {'draft': True}, {}, '400'))
            self.assertIn('could not be confirmed', report([], None, {}, '400'))
        self.assertEqual(duration(None, None), 'unfinished')


if __name__ == '__main__':
    unittest.main()
