# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Admission and retirement contend on the same durable reservation revision."""

import copy
from contextlib import nullcontext
import json
import os
from pathlib import Path
import sys
import threading
from types import SimpleNamespace
import unittest

from fixture_git import FixtureTestCase
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import candidate_reservation as reservation

SHA = 'a' * 40
MAC = {'run': 10, 'attempt': 1, 'sha': SHA, 'ref': reservation.BRANCH,
       'workflow': '.github/workflows/release.yml'}
IOS = {'run': 20, 'attempt': 1, 'sha': 'b' * 40, 'ref': 'refs/heads/main',
       'workflow': '.github/workflows/ios-testflight.yml'}


class DeliveryAdmissionTests(FixtureTestCase):
    def setUp(self):
        self.lock = threading.Lock()
        self.revision = 1
        self.refs = {reservation.BRANCH: SHA, reservation.RESERVATION: f'{self.revision:040x}'}
        self.data = {'schema': 2, 'sha': SHA, 'state': 'reserved', 'claims': {}}
        self.checks = Mock()
        self.checks.api.return_value = [{'workflow_runs': []}]
        for name, function in [('snapshot', self.snapshot), ('write', self.write)]:
            mock = patch.object(reservation, name, side_effect=function)
            mock.start()
            self.addCleanup(mock.stop)

    def snapshot(self):
        with self.lock:
            return copy.deepcopy((self.refs, self.data))

    def write(self, refs, sha, state, claims=None):
        with self.lock:
            if refs[reservation.RESERVATION] != self.refs[reservation.RESERVATION]:
                raise ValueError('reservation changed')
            self.revision += 1
            self.refs[reservation.RESERVATION] = f'{self.revision:040x}'
            self.data = {'schema': 2, 'sha': sha, 'state': state, 'claims': copy.deepcopy(claims or {})}
            if state == 'reserved' and claims is None:
                self.refs[reservation.BRANCH] = sha

    def objects(self, path):
        if path == 'git/ref/heads/candidate-reservation':
            return {'object': {'type': 'commit', 'sha': self.refs[reservation.RESERVATION]}}
        return {'message': json.dumps(self.data)}

    def thread(self, function):
        errors = []
        def execute():
            try:
                function()
            except Exception as error:
                errors.append(error)
        worker = threading.Thread(target=execute)
        worker.start()
        return worker, errors

    def join(self, worker):
        worker.join(120)
        self.assertFalse(worker.is_alive(), 'fixture interleaving did not finish')

    def test_retirement_fences_before_delivery_snapshot_and_denies_new_admission(self):
        barrier = threading.Barrier(2, timeout=120)
        def snapshot_deliveries(checks):
            barrier.wait()
            barrier.wait()
        with patch.object(reservation, 'quiescent', side_effect=snapshot_deliveries):
            worker, errors = self.thread(lambda: reservation.finish(SHA, 'released', self.checks))
            barrier.wait()
            try:
                self.assertEqual(self.data['state'], 'closing')
                with self.assertRaises(ValueError):
                    reservation.admit(SHA, MAC)
                with self.assertRaises(ValueError):
                    reservation.require(SHA, self.objects)
            finally:
                barrier.wait()
                self.join(worker)
        self.assertEqual(errors, [])
        self.assertEqual(self.data['state'], 'released')

    def test_admission_winning_cas_prevents_retirement_until_delivery_exits(self):
        barrier = threading.Barrier(2, timeout=120)
        def closing(refs, sha, state, claims=None):
            if state == 'closing':
                barrier.wait()
                barrier.wait()
            self.write(refs, sha, state, claims)
        with patch.object(reservation, 'write', side_effect=closing):
            worker, errors = self.thread(lambda: reservation.finish(SHA, 'released', self.checks))
            barrier.wait()
            try:
                reservation.admit(SHA, MAC)
            finally:
                barrier.wait()
                self.join(worker)
        self.assertEqual(len(errors), 1)
        self.assertEqual(self.data['state'], 'reserved')
        with self.assertRaisesRegex(ValueError, 'admitted'):
            reservation.finish(SHA, 'released', self.checks)
        with self.assertRaises(ValueError):
            reservation.reserve('c' * 40, False, self.checks)
        reservation.depart(SHA, MAC)
        reservation.finish(SHA, 'released', self.checks)
        reservation.reserve('c' * 40, False, self.checks)
        with self.assertRaises(ValueError):
            reservation.admit(SHA, MAC)

    def test_simultaneous_mac_and_ios_claims_survive_each_others_updates(self):
        barrier = threading.Barrier(2, timeout=120)
        first = threading.local()
        def snapshot():
            result = self.snapshot()
            if not getattr(first, 'seen', False):
                first.seen = True
                barrier.wait()
            return result
        with patch.object(reservation, 'snapshot', side_effect=snapshot):
            mac, mac_errors = self.thread(lambda: reservation.admit(SHA, MAC))
            ios, ios_errors = self.thread(lambda: reservation.admit(SHA, IOS))
            self.join(mac)
            self.join(ios)
        self.assertEqual(mac_errors + ios_errors, [])
        self.assertEqual(len(self.data['claims']), 2)
        reservation.depart(SHA, MAC)
        self.assertEqual(list(self.data['claims'].values()), [IOS])
        with self.assertRaisesRegex(ValueError, 'admitted'):
            reservation.finish(SHA, 'abandoned', self.checks)
        reservation.depart(SHA, IOS)
        reservation.finish(SHA, 'abandoned', self.checks)
        self.assertEqual(self.data['state'], 'abandoned')

    def test_closing_is_durable_when_the_delivery_lookup_fails(self):
        self.checks.api.side_effect = ValueError('lookup failed')
        with self.assertRaisesRegex(ValueError, 'lookup failed'):
            reservation.finish(SHA, 'released', self.checks)
        self.assertEqual(self.data['state'], 'closing')
        with self.assertRaises(ValueError):
            reservation.reserve('c' * 40, False, self.checks)

    def test_claim_checks_bind_run_attempt_source_and_workflow_ref(self):
        reservation.admit(SHA, MAC)
        env = {'GITHUB_REPOSITORY': 'Se7enbrc/glimmer', 'GITHUB_EVENT_NAME': 'workflow_dispatch',
               'GITHUB_RUN_ID': '10', 'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_SHA': SHA,
               'GITHUB_REF': reservation.BRANCH,
               'GITHUB_WORKFLOW_REF': 'Se7enbrc/glimmer/' + MAC['workflow'] + '@' + MAC['ref']}
        with patch.dict(os.environ, env, clear=True):
            reservation.require(SHA, self.objects, delivery=True)
            self.data['state'] = 'closing'
            reservation.require(SHA, self.objects, delivery=True)
            for key, value in [('GITHUB_RUN_ID', '11'), ('GITHUB_RUN_ATTEMPT', '2'),
                               ('GITHUB_SHA', 'c' * 40), ('GITHUB_REF', 'refs/heads/main'),
                               ('GITHUB_WORKFLOW_REF', 'other')]:
                with self.subTest(key=key), patch.dict(os.environ, {key: value}), self.assertRaises(ValueError):
                    reservation.require(SHA, self.objects, delivery=True)
        reservation.depart(SHA, MAC)
        with patch.dict(os.environ, env, clear=True), self.assertRaises(ValueError):
            reservation.require(SHA, self.objects, delivery=True)

    def test_new_attempt_requires_its_own_claim_and_old_completion_cannot_clear_it(self):
        reservation.admit(SHA, MAC)
        newer = {**MAC, 'attempt': 2}
        reservation.admit(SHA, newer)
        reservation.depart(SHA, MAC)
        self.assertEqual(list(self.data['claims'].values()), [newer])
        with self.assertRaisesRegex(ValueError, 'admitted'):
            reservation.finish(SHA, 'released', self.checks)
        with self.assertRaises(ValueError):
            reservation.admit(SHA, {**IOS, 'attempt': 3})

    def test_changed_identity_and_failed_claim_writes_never_authorize(self):
        reservation.admit(SHA, MAC)
        with self.assertRaises(ValueError):
            reservation.admit(SHA, {**MAC, 'sha': 'd' * 40})
        with patch.object(reservation, 'write', side_effect=ValueError('lost lease')):
            with self.assertRaises(ValueError):
                reservation.admit(SHA, IOS)
            with self.assertRaises(ValueError):
                reservation.depart(SHA, MAC)
        self.assertEqual(list(self.data['claims'].values()), [MAC])

    def test_retired_records_cannot_carry_claims_and_schema_two_requires_them(self):
        for data in ({'schema': 2, 'sha': SHA, 'state': 'reserved'},
                     {'schema': 2, 'sha': SHA, 'state': 'released', 'claims': {'10:1': MAC}},
                     {'schema': 2, 'sha': SHA, 'state': 'reserved', 'claims': {'10:2': MAC}}):
            with self.subTest(data=data), self.assertRaises(ValueError):
                reservation.record(json.dumps(data))

    def test_admission_wait_is_bounded_and_does_not_retry_a_closed_reservation(self):
        self.checks.read_budget.return_value = nullcontext()
        clock = SimpleNamespace(monotonic=Mock(side_effect=[0, 0, 1200, 1200]), sleep=Mock())
        with patch.object(reservation, 'time', clock), \
                patch.object(reservation, 'require', side_effect=reservation.AdmissionPending('pending')):
            with self.assertRaisesRegex(ValueError, 'timed out'):
                reservation.wait(SHA, self.checks.object_api, self.checks.read_budget)
        self.checks.read_budget.assert_called_once_with(1200)
        clock = SimpleNamespace(monotonic=Mock(return_value=0), sleep=Mock())
        with patch.object(reservation, 'time', clock), \
                patch.object(reservation, 'require', side_effect=ValueError('closed')):
            with self.assertRaisesRegex(ValueError, 'closed'):
                reservation.wait(SHA, self.checks.object_api, self.checks.read_budget)
        clock.sleep.assert_not_called()
