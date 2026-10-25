# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Diagnostic identity is explicit and cannot be inferred from truthy plist values."""

from pathlib import Path
import sys
import unittest

from fixture_git import FixtureTestCase

sys.path.insert(0, str(Path(__file__).parents[1]))
from release_candidate_kind import diagnostic_marker, parse_tag, validate_marker


class CandidateKindTests(FixtureTestCase):
    def test_tag_parser_accepts_only_explicit_candidate_forms(self):
        self.assertEqual(parse_tag('2026.10.8-rc.12'), ('2026.10.8', 12, False))
        self.assertEqual(parse_tag('2026.10.8-rc.13-diag'), ('2026.10.8', 13, True))
        for tag in ('2026.10.8', '2026.10.8-diag', '2026.10.8-rc.0-diag', '2026.10.8-rc.1-diag-extra'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                parse_tag(tag)

    def test_marker_accepts_only_bools_or_build_setting_strings(self):
        for value in (True, 'YES'):
            validate_marker({'GlimmerDiagnosticBuild': value}, '2026.10.8-rc.1-diag')
        for value in (False, 'NO'):
            validate_marker({'GlimmerDiagnosticBuild': value}, '2026.10.8-rc.1')
        for value in (1, 0, None, 'true', 'false', '', '$(GLIMMER_DIAGNOSTIC_BUILD)'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                diagnostic_marker({'GlimmerDiagnosticBuild': value})
        self.assertFalse(diagnostic_marker({}))  # Previously published ordinary candidates.

    def test_marker_mismatch_blocks_both_directions(self):
        for info, tag in (({}, '2026.10.8-rc.1-diag'),
                          ({'GlimmerDiagnosticBuild': 'YES'}, '2026.10.8-rc.1')):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                validate_marker(info, tag)
