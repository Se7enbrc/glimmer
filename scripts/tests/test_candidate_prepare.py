# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Preparation waits only for the held candidate's direct, completed evidence."""

import importlib.util
from pathlib import Path
import sys
import unittest

from fixture_git import FixtureTestCase
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
SPEC = importlib.util.spec_from_file_location('cutter', Path(__file__).parents[1] / 'release-candidate.py')
CUTTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CUTTER)
SHA = 'a' * 40


class CandidatePrepareTests(FixtureTestCase):
    def test_new_reservation_waits_for_new_dispatches_not_old_green_runs(self):
        with patch.object(CUTTER.candidate_reservation, 'reserve', return_value=True), \
                patch.object(CUTTER, 'candidate_runs', return_value=[{'id': 1}]), \
                patch.object(CUTTER, 'step') as step, patch.object(CUTTER.CHECKS, 'check') as check, \
                patch.object(CUTTER.time, 'monotonic', side_effect=[0, 1, 2, 2700]), \
                patch.object(CUTTER.time, 'sleep') as sleep:
            with self.assertRaisesRegex(ValueError, 'timed out; reservation retained'):
                CUTTER.prepare_candidate(SHA, False)
        self.assertEqual(step.call_count, 2)
        check.assert_not_called()
        sleep.assert_called_once_with(60)

    def test_resume_waits_on_processing_without_redispatch_and_stops_at_deadline(self):
        with patch.object(CUTTER.candidate_reservation, 'reserve', return_value=False), \
                patch.object(CUTTER, 'candidate_runs', return_value=[{'id': 1}]), \
                patch.object(CUTTER, 'step') as step, \
                patch.object(CUTTER.CHECKS, 'check', side_effect=CUTTER.CHECKS.ChecksPending('processing')), \
                patch.object(CUTTER.time, 'monotonic', side_effect=[0, 1, 2699, 2700]), \
                patch.object(CUTTER.time, 'sleep') as sleep:
            with self.assertRaisesRegex(ValueError, 'timed out'):
                CUTTER.prepare_candidate(SHA, False)
        step.assert_not_called()
        sleep.assert_called_once_with(1)

    def test_terminal_failure_never_sleeps_or_dispatches_a_replacement(self):
        with patch.object(CUTTER.candidate_reservation, 'reserve', return_value=False), \
                patch.object(CUTTER, 'candidate_runs', return_value=[{'id': 1}]), \
                patch.object(CUTTER, 'step') as step, \
                patch.object(CUTTER.CHECKS, 'check', side_effect=ValueError('failed attempt')), \
                patch.object(CUTTER.time, 'sleep') as sleep:
            with self.assertRaisesRegex(ValueError, 'failed attempt'):
                CUTTER.prepare_candidate(SHA, False)
        step.assert_not_called()
        sleep.assert_not_called()

    def test_first_preparation_checks_direct_evidence_after_both_dispatches(self):
        with patch.object(CUTTER.candidate_reservation, 'reserve', return_value=True), \
                patch.object(CUTTER, 'candidate_runs', side_effect=[[], [], [{'id': 1}], [{'id': 2}]]), \
                patch.object(CUTTER, 'step') as step, patch.object(CUTTER.CHECKS, 'check') as check:
            CUTTER.prepare_candidate(SHA, False)
        self.assertEqual(step.call_count, 2)
        check.assert_called_once_with(SHA, candidate=True)
