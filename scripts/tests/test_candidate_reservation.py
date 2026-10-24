# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""A durable compare-and-swap reservation protects both delivery platforms."""

import os
import unittest
from unittest.mock import Mock, patch
import test_release_candidate_cut as fixture
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))
import candidate_reservation as reservation


class CandidateReservationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixture.ReleaseCandidateCutTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.original = Path.cwd()
        os.chdir(self.fixture.work)
        self.addCleanup(os.chdir, self.original)
        env = patch.dict(os.environ, self.fixture.env, clear=True)
        env.start()
        self.addCleanup(env.stop)
        self.checks = Mock()
        self.checks.api.return_value = [{'workflow_runs': []}]
        self.sha = self.fixture.sha

    def test_shared_hold_survives_failed_or_cancelled_deliveries_until_explicit_finish(self):
        self.assertTrue(reservation.reserve(self.sha, False, self.checks))
        self.assertFalse(reservation.reserve(self.sha, False, self.checks))
        self.checks.api.return_value = [{'workflow_runs': [{'status': 'completed', 'conclusion': 'failure'}]}]
        with self.assertRaisesRegex(ValueError, 'reserved'):
            reservation.reserve(self.fixture.old, False, self.checks)
        reservation.finish(self.sha, 'abandoned', self.checks)
        self.assertTrue(reservation.reserve(self.fixture.old, False, self.checks))

    def test_pending_mac_or_ios_prevents_release_and_abandon(self):
        reservation.reserve(self.sha, False, self.checks)
        for workflow in reservation.DELIVERIES:
            self.checks.api.side_effect = lambda path: [{'workflow_runs': [
                {'status': 'waiting'}] if workflow in path else []}]
            for state in ('released', 'abandoned'):
                with self.subTest(workflow=workflow, state=state), self.assertRaisesRegex(ValueError, 'pending'):
                    reservation.finish(self.sha, state, self.checks)
        self.assertEqual(reservation.snapshot()[1]['state'], 'reserved')

    def test_simultaneous_cuts_cannot_replace_the_winning_reservation_or_branch(self):
        refs, _ = reservation.snapshot()
        reservation.write(refs, self.sha, 'reserved')
        with self.assertRaises(ValueError):
            reservation.write(refs, self.fixture.old, 'reserved')
        current, data = reservation.snapshot()
        self.assertEqual(current[reservation.BRANCH], self.sha)
        self.assertEqual(data['sha'], self.sha)

    def test_release_cas_cannot_clear_a_replacement_and_same_source_cannot_reopen(self):
        reservation.reserve(self.sha, False, self.checks)
        stale, _ = reservation.snapshot()
        reservation.finish(self.sha, 'released', self.checks)
        with self.assertRaisesRegex(ValueError, 'new source commit'):
            reservation.reserve(self.sha, False, self.checks)
        reservation.reserve(self.fixture.old, False, self.checks)
        with self.assertRaises(ValueError):
            reservation.write(stale, self.sha, 'released')
        self.assertEqual(reservation.snapshot()[1]['sha'], self.fixture.old)

    def test_movement_missing_state_and_truncated_history_fail_closed(self):
        with self.assertRaises(ValueError):
            reservation.finish(self.sha, 'released', self.checks)
        self.checks.api.return_value = [{'total_count': 1000, 'workflow_runs': []}]
        with self.assertRaisesRegex(ValueError, 'truncated'):
            reservation.reserve(self.sha, False, self.checks)
        self.checks.api.return_value = [{'workflow_runs': []}]
        reservation.reserve(self.sha, False, self.checks)
        self.fixture.git('push', '--force', 'origin', f'{self.fixture.old}:{reservation.BRANCH}')
        with self.assertRaisesRegex(ValueError, 'moved'):
            reservation.reserve(self.sha, False, self.checks)
        with self.assertRaises(ValueError):
            reservation.finish(self.sha, 'abandoned', self.checks)

    def test_invalid_delivery_lookup_cannot_release_the_hold(self):
        reservation.reserve(self.sha, False, self.checks)
        for pages in ([], [{}], [{'workflow_runs': None}]):
            self.checks.api.return_value = pages
            with self.assertRaisesRegex(ValueError, 'invalid data'):
                reservation.finish(self.sha, 'released', self.checks)
        self.assertEqual(reservation.snapshot()[1]['state'], 'reserved')

    def test_dry_run_never_allocates_or_moves_refs(self):
        before = self.fixture.remote()
        reservation.reserve(self.sha, True, self.checks)
        self.assertEqual(self.fixture.remote(), before)
