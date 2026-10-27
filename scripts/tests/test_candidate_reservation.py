# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""A durable compare-and-swap reservation protects both delivery platforms."""

import os
import io
import json
from contextlib import redirect_stdout
import unittest

from fixture_git import FixtureTestCase
from unittest.mock import Mock, patch
import test_release_candidate_cut as fixture
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))
import candidate_reservation as reservation


class CandidateReservationTests(FixtureTestCase):
    def setUp(self):
        self.fixture = fixture.ReleaseCandidateCutTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.original = Path.cwd()
        os.chdir(self.fixture.work)
        self.addCleanup(os.chdir, self.original)
        env = patch.dict(os.environ, self.fixture.env, clear=True)
        env.start()
        self.addCleanup(env.stop)
        self.checks = Mock()
        self.checks.api.return_value = [{'workflow_runs': []}]
        self.sha = self.fixture.sha

    def hold_previous(self):
        reservation.reserve(self.fixture.old, False, self.checks)
        self.checks.api.side_effect = lambda path: [[]] if path.startswith('releases?') else [{'workflow_runs': []}]

    def history(self):
        refs, _ = reservation.snapshot()
        return [reservation.record(message) for message in
                self.fixture.git('log', '--format=%B%x00', refs[reservation.RESERVATION]).split('\0')
                if message.strip()]

    def test_higher_build_atomically_abandons_previous_candidate_and_records_successor(self):
        self.hold_previous()
        before = reservation.snapshot()[0][reservation.RESERVATION]
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertTrue(reservation.reserve(self.sha, False, self.checks))
        refs, data = reservation.snapshot()
        self.assertEqual((refs[reservation.BRANCH], data['sha'], data['state']), (self.sha, self.sha, 'reserved'))
        self.assertEqual(self.fixture.git('rev-parse', refs[reservation.RESERVATION] + '^^'), before)
        self.assertEqual(self.history()[1], {'schema': 2, 'sha': self.fixture.old, 'state': 'abandoned',
                                           'claims': {}, 'superseded_by': self.sha})
        self.assertEqual(output.getvalue().splitlines(), [
            f'Abandoned candidate {self.fixture.old}, superseded by {self.sha}, in the atomic reservation'])

    def test_dry_run_names_retirement_without_changing_refs_or_history(self):
        self.hold_previous()
        before = self.fixture.remote()
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertTrue(reservation.reserve(self.sha, True, self.checks))
        self.assertEqual(self.fixture.remote(), before)
        self.assertIn(f'Would abandon candidate {self.fixture.old}, superseded by {self.sha}', output.getvalue())
        self.assertEqual(len(self.history()), 1)

    def test_each_active_delivery_status_blocks_replacement_and_dry_run_with_run_identity(self):
        self.hold_previous()
        before = self.fixture.remote()
        for workflow in reservation.DELIVERIES:
            for status in ('queued', 'in_progress', 'waiting', 'pending', 'requested'):
                for dry_run in (False, True):
                    self.checks.api.side_effect = lambda path: [[]] if path.startswith('releases?') else [{
                        'workflow_runs': [{'id': 42, 'status': status, 'head_sha': self.fixture.old}]
                        if workflow in path else []}]
                    with self.subTest(workflow=workflow, status=status, dry_run=dry_run):
                        with self.assertRaisesRegex(ValueError, f'{workflow} run 42 .*{status}'):
                            reservation.reserve(self.sha, dry_run, self.checks)
                        self.assertEqual(self.fixture.remote(), before)

    def test_main_promotion_approval_blocks_replacement(self):
        self.hold_previous()
        self.checks.api.side_effect = lambda path: [[]] if path.startswith('releases?') else [{
            'workflow_runs': [{'id': 90, 'status': 'waiting', 'head_sha': 'f' * 40,
                               'head_branch': 'main'}] if 'release.yml' in path else []}]
        with self.assertRaisesRegex(ValueError, 'release.yml run 90 .*waiting'):
            reservation.reserve(self.sha, False, self.checks)
        self.assertEqual(reservation.snapshot()[1]['sha'], self.fixture.old)

    def test_completed_deliveries_allow_replacement(self):
        for conclusion in ('success', 'failure', 'cancelled'):
            with self.subTest(conclusion=conclusion), patch.object(reservation, 'snapshot', return_value=(
                    {reservation.BRANCH: self.fixture.old}, {'sha': self.fixture.old, 'state': 'reserved', 'claims': {}})), \
                    patch.object(reservation, 'write') as write:
                self.checks.api.side_effect = lambda path: [[]] if path.startswith('releases?') else [{
                    'workflow_runs': [{'status': 'completed', 'conclusion': conclusion}]}]
                reservation.reserve(self.sha, False, self.checks)
                write.assert_called_once_with({reservation.BRANCH: self.fixture.old}, self.sha, 'reserved',
                                              superseded=self.fixture.old)

    def test_equal_lower_different_or_invalid_versions_cannot_replace(self):
        self.hold_previous()
        before = self.fixture.remote()
        for version, build in ((fixture.VERSION, '20261009'), (fixture.VERSION, '20261008'),
                               ('2026.11.1', fixture.BUILD), (fixture.VERSION, 'bad')):
            self.fixture.commit(build)
            config = self.fixture.work / 'Glimmer/Version.xcconfig'
            config.write_text(f'MARKETING_VERSION = {version}\nCURRENT_PROJECT_VERSION = {build}\n')
            self.fixture.git('add', '-A')
            self.fixture.git('commit', '--quiet', '--allow-empty', '-m', 'candidate version')
            sha = self.fixture.git('rev-parse', 'HEAD')
            with self.subTest(version=version, build=build), self.assertRaisesRegex(ValueError, 'version|metadata'):
                reservation.reserve(sha, False, self.checks)
            self.assertEqual(self.fixture.remote(), before)

    def test_final_tag_and_promoted_release_each_prevent_abandonment(self):
        self.hold_previous()
        for tag in (fixture.VERSION, f'{fixture.VERSION}-rc.19'):
            for dry_run in (False, True):
                self.checks.api.side_effect = lambda path: [[{'tag_name': tag, 'prerelease': False}]]
                with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, 'GA release'):
                    reservation.reserve(self.sha, dry_run, self.checks)
        self.fixture.tag_origin(fixture.VERSION)
        before = self.fixture.remote()
        with self.assertRaisesRegex(ValueError, 'final tag'):
            reservation.reserve(self.sha, False, self.checks)
        self.assertEqual(self.fixture.remote(), before)

    def test_prerelease_and_other_versions_do_not_block_replacement(self):
        self.hold_previous()
        self.checks.api.side_effect = lambda path: [[
            {'tag_name': f'{fixture.VERSION}-rc.19', 'prerelease': True},
            {'tag_name': '2026.9.1-rc.1', 'prerelease': False}]] if path.startswith('releases?') else [{'workflow_runs': []}]
        reservation.reserve(self.sha, False, self.checks)
        self.assertEqual(self.history()[1]['state'], 'abandoned')

    def test_missing_release_evidence_fails_closed(self):
        self.hold_previous()
        before = self.fixture.remote()
        for pages in ([], [{}], [[{}]], [[{'tag_name': fixture.VERSION}]]):
            self.checks.api.side_effect = None
            self.checks.api.return_value = pages
            with self.subTest(pages=pages), self.assertRaises(ValueError):
                reservation.reserve(self.sha, False, self.checks)
            self.assertEqual(self.fixture.remote(), before)

    def test_released_record_stays_released_when_next_candidate_is_reserved(self):
        self.hold_previous()
        reservation.finish(self.fixture.old, 'released', self.checks)
        reservation.reserve(self.sha, False, self.checks)
        self.assertEqual([entry['state'] for entry in self.history()], ['reserved', 'released', 'closing', 'reserved'])

    def test_legacy_reservation_can_be_superseded_without_changing_its_record(self):
        self.hold_previous()
        legacy = json.dumps({'schema': 1, 'sha': self.fixture.old, 'state': 'reserved'})
        commit = self.fixture.git('commit-tree', reservation.git('mktree', input=''), '-m', legacy)
        self.fixture.git('push', '--force', 'origin', f'{commit}:{reservation.RESERVATION}')
        reservation.reserve(self.sha, False, self.checks)
        self.assertEqual(self.history()[2]['schema'], 1)

    def test_admission_racing_replacement_preserves_old_hold_and_claim(self):
        self.hold_previous()
        identity = {'run': 12, 'attempt': 1, 'sha': self.fixture.old, 'ref': reservation.BRANCH,
                    'workflow': '.github/workflows/release.yml'}
        with patch.object(reservation, 'quiescent', side_effect=lambda _: reservation.admit(self.fixture.old, identity)):
            with self.assertRaisesRegex(ValueError, 'reload state'):
                reservation.reserve(self.sha, False, self.checks)
        refs, data = reservation.snapshot()
        self.assertEqual(refs[reservation.BRANCH], self.fixture.old)
        self.assertEqual(data['claims'], {'12:1': identity})
        self.assertNotIn('abandoned', [entry['state'] for entry in self.history()])
        with self.assertRaisesRegex(ValueError, 'release.yml run 12 attempt 1'):
            reservation.reserve(self.sha, False, self.checks)

    def test_branch_lease_failure_cannot_publish_retirement(self):
        self.hold_previous()
        before = reservation.snapshot()[0][reservation.RESERVATION]
        moved = self.fixture.commit('20261011')
        with patch.object(reservation, 'quiescent', side_effect=lambda _: self.fixture.git(
                'push', '--force', 'origin', f'{moved}:{reservation.BRANCH}')):
            with self.assertRaises(ValueError):
                reservation.reserve(self.sha, False, self.checks)
        self.assertEqual(reservation.snapshot()[0][reservation.RESERVATION], before)
        with self.assertRaisesRegex(ValueError, 'branch moved'):
            reservation.reserve(self.sha, False, self.checks)

    def test_concurrent_supersessions_cannot_publish_two_holds(self):
        self.hold_previous()
        stale, _ = reservation.snapshot()
        winner = self.fixture.commit('20261011')
        reservation.reserve(winner, False, self.checks)
        with self.assertRaises(ValueError):
            reservation.write(stale, self.sha, 'reserved', superseded=self.fixture.old)
        refs, data = reservation.snapshot()
        self.assertEqual((refs[reservation.BRANCH], data['sha']), (winner, winner))
        self.assertEqual(self.history()[1]['superseded_by'], winner)
        self.assertEqual(len(self.history()), 3)

    def test_closing_candidate_cannot_be_automatically_replaced(self):
        self.hold_previous()
        refs, _ = reservation.snapshot()
        reservation.write(refs, self.fixture.old, 'closing', {})
        before = self.fixture.remote()
        with self.assertRaisesRegex(ValueError, 'closing'):
            reservation.reserve(self.sha, False, self.checks)
        self.assertEqual(self.fixture.remote(), before)

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
        self.assertEqual(reservation.snapshot()[1]['state'], 'closing')

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
        self.assertEqual(reservation.snapshot()[1]['state'], 'closing')

    def test_dry_run_never_allocates_or_moves_refs(self):
        before = self.fixture.remote()
        reservation.reserve(self.sha, True, self.checks)
        self.assertEqual(self.fixture.remote(), before)

    def test_real_ref_lease_serializes_admission_and_retirement(self):
        reservation.reserve(self.sha, False, self.checks)
        stale, _ = reservation.snapshot()
        identity = {'run': 12, 'attempt': 1, 'sha': self.sha, 'ref': reservation.BRANCH,
                    'workflow': '.github/workflows/release.yml'}
        reservation.admit(self.sha, identity)
        with self.assertRaises(ValueError):
            reservation.write(stale, self.sha, 'closing', {})
        with self.assertRaisesRegex(ValueError, 'admitted'):
            reservation.finish(self.sha, 'released', self.checks)
        current, data = reservation.snapshot()
        self.assertEqual(data['claims'], {'12:1': identity})
        self.assertEqual(current[reservation.BRANCH], self.sha)
        reservation.depart(self.sha, identity)
        reservation.finish(self.sha, 'released', self.checks)
        self.assertEqual(reservation.snapshot()[1]['state'], 'released')
