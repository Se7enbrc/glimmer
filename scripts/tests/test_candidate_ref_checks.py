# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Candidate authorization stays on X while pull request analysis moves on."""

import json
import unittest
from unittest.mock import patch
from test_release_checks import CHECKS, SHA, MERGE, WORKFLOW, analyses, language_jobs, run

REF = 'refs/heads/release-candidate'


class CandidateRefChecksTests(unittest.TestCase):
    def setUp(self):
        self.data = analyses(ref=REF, commit_sha=SHA)
        for entry in self.data:
            entry['sarif_id'] = f"upload-{entry['id']}"
        self.runs = [run(event='workflow_dispatch', head_branch='release-candidate')]
        self.jobs = language_jobs(head_branch='release-candidate')
        for entry in self.data:
            self.jobs[CHECKS.CATEGORIES[entry['category']]]['steps'] = [
                {'name': f"CodeQL upload {entry['sarif_id']}",
                 'status': 'completed', 'conclusion': 'success'}]
        self.alerts = []
        self.branch = SHA
        self.processing = 'complete'
        self.reads = []

    def objects(self, path):
        self.reads.append(path)
        if path == 'git/ref/heads/candidate-reservation':
            return {'object': {'type': 'commit', 'sha': 'c' * 40}}
        if path == f"git/commits/{'c' * 40}":
            return {'message': json.dumps({'schema': 1, 'state': 'reserved', 'sha': SHA})}
        if path == 'git/ref/heads/release-candidate':
            return {'object': {'type': 'commit', 'sha': self.branch}}
        if path.startswith('actions/workflows/'):
            workflow = next(value for value in CHECKS.REQUIRED if value.replace('/', '%2F') in path)
            return {'path': workflow, 'state': 'active', 'id': 2 if workflow == WORKFLOW else 3}
        if path.startswith('code-scanning/sarifs/'):
            return {'processing_status': self.processing}
        raise AssertionError(path)

    def pages(self, path):
        self.reads.append(path)
        if '/runs?' in path:
            workflow = WORKFLOW if '/2/' in path else '.github/workflows/verify.yml'
            return [{'workflow_runs': [{**r, 'workflow_id': 2 if workflow == WORKFLOW else 3,
                                        'path': workflow} for r in self.runs]}]
        if '/jobs?' in path:
            return [{'jobs': [*self.jobs.values(), {'name': 'macOS', 'head_sha': SHA,
                                                   'status': 'completed', 'conclusion': 'success',
                                                   'run_id': 1, 'run_attempt': 1,
                                                   'head_branch': 'release-candidate'}]}]
        if 'analyses?' in path:
            # Candidate evidence can be beyond the first page.
            return [analyses(id=100, ref='refs/pull/114/merge', commit_sha=MERGE), self.data]
        if 'alerts?' in path:
            self.assertIn('ref=refs%2Fheads%2Frelease-candidate', path)
            return [self.alerts]
        raise AssertionError(path)

    def check(self):
        with patch.object(CHECKS, 'object_api', side_effect=self.objects), \
                patch.object(CHECKS, 'api', side_effect=self.pages):
            return CHECKS.check(SHA, candidate=True)

    def test_pr_movement_and_same_head_merge_regeneration_do_not_replace_candidate(self):
        self.runs.extend([run(id=20, run_number=20, head_sha=MERGE), run(id=21, run_number=21)])
        evidence = self.check()
        self.assertEqual(evidence['analysis_ref'], REF)
        self.assertEqual({entry['id'] for entry in evidence['analyses']}, {1, 2, 3})
        self.assertEqual({entry['sarif_id'] for entry in evidence['analyses']},
                         {'upload-1', 'upload-2', 'upload-3'})

    def test_no_fallback_to_pr_or_older_candidate_after_failed_or_pending_attempt(self):
        for newer in ({'run_attempt': 2}, {'id': 2, 'run_number': 5}):
            for status, conclusion in [('in_progress', None), ('completed', 'failure'), ('completed', 'cancelled')]:
                with self.subTest(newer=newer, status=status, conclusion=conclusion):
                    self.runs.append({**self.runs[0], **newer, 'status': status, 'conclusion': conclusion})
                    with self.assertRaises(ValueError):
                        self.check()
                    self.runs.pop()
        self.runs = [run()]
        with self.assertRaises(ValueError):
            self.check()

    def test_later_rerun_of_older_run_cannot_hide_behind_newer_run_number(self):
        for status, conclusion in [('queued', None), ('in_progress', None),
                                   ('completed', 'failure'), ('completed', 'cancelled')]:
            with self.subTest(status=status, conclusion=conclusion):
                self.runs = [
                    run(id=11, run_number=11, event='workflow_dispatch', head_branch='release-candidate'),
                    run(id=10, run_number=10, run_attempt=2, event='workflow_dispatch',
                        head_branch='release-candidate', run_started_at='2026-10-09T21:00:00Z',
                        status=status, conclusion=conclusion)]
                with self.assertRaises(ValueError):
                    self.check()

    def test_new_upload_after_successful_job_cannot_borrow_its_verdict(self):
        self.data[0].update(id=50, created_at='2026-10-09T21:01:00Z', sarif_id='failed-upload')
        with self.assertRaises(ValueError):
            self.check()

    def test_overlapping_upload_and_mixed_job_identity_cannot_authorize(self):
        self.data[0]['sarif_id'] = 'other-run-upload'
        with self.assertRaises(ValueError):
            self.check()
        self.data[0]['sarif_id'] = 'upload-1'
        for changes in ({'run_id': 2}, {'run_attempt': 3}, {'head_branch': 'main'}):
            with self.subTest(changes=changes):
                job = self.jobs['Analyze (swift)']
                original = dict(job)
                job.update(changes)
                with self.assertRaises(ValueError):
                    self.check()
                job.clear()
                job.update(original)

    def test_verify_and_codeql_each_reject_a_later_failed_older_run(self):
        original = self.pages
        for workflow_id in (2, 3):
            def failed_rerun(path):
                result = original(path)
                if f'/workflows/{workflow_id}/runs?' in path:
                    newer = result[0]['workflow_runs'][0]
                    newer.update(id=11, run_number=11)
                    result[0]['workflow_runs'].append({
                        **newer, 'id': 10, 'run_number': 10, 'run_attempt': 2,
                        'updated_at': '2026-10-09T21:02:00Z', 'conclusion': 'failure'})
                return result
            with self.subTest(workflow_id=workflow_id), patch.object(self, 'pages', side_effect=failed_rerun):
                with self.assertRaisesRegex(ValueError, 'not green'):
                    self.check()

    def test_receipt_must_be_unique_and_successful_and_identity_must_be_complete(self):
        job = self.jobs['Analyze (swift)']
        receipt = job['steps'][0]
        for steps in ([], [receipt, receipt], [{**receipt, 'conclusion': 'failure'}]):
            job['steps'] = steps
            with self.subTest(steps=steps), self.assertRaises(ValueError):
                self.check()
        job['steps'] = [receipt]
        for field in ('run_attempt', 'run_id', 'head_branch', 'completed_at'):
            saved = job.pop(field)
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check()
            job[field] = saved

    def test_wrong_sha_ref_configuration_or_mixed_categories_fail(self):
        for field, value in [('commit_sha', MERGE), ('ref', 'refs/heads/feature'),
                             ('category', '/language:ruby'), ('analysis_key', 'other:analyze')]:
            with self.subTest(field=field):
                saved = self.data[0][field]
                self.data[0][field] = value
                with self.assertRaises(ValueError):
                    self.check()
                self.data[0][field] = saved

    def test_open_candidate_alert_blocks_even_when_feature_is_fixed_and_reopening_blocks(self):
        self.check()
        self.alerts = [{'number': 1, 'state': 'open'}]
        with self.assertRaisesRegex(ValueError, 'open CodeQL alerts'):
            self.check()
        self.alerts = []  # A current global dismissal clears the ref-scoped open query.
        self.check()

    def test_movement_before_or_during_alert_read_fails(self):
        self.branch = MERGE
        with self.assertRaises(ValueError):
            self.check()
        self.branch = SHA
        original = self.pages

        def moving(path):
            result = original(path)
            if 'alerts?' in path:
                self.branch = MERGE
            return result

        with patch.object(self, 'pages', side_effect=moving), self.assertRaises(ValueError):
            self.check()

    def test_analysis_or_latest_run_changes_around_alert_read_fail(self):
        original = self.pages
        for change in ('analysis', 'run'):
            def changing(path):
                result = original(path)
                if 'alerts?' in path:
                    if change == 'analysis':
                        self.data[0] = {**self.data[0], 'id': 55}
                    else:
                        self.runs.append({**self.runs[0], 'id': 55, 'run_number': 55})
                return result
            with patch.object(self, 'pages', side_effect=changing), self.assertRaises(ValueError):
                self.check()

    def test_processing_must_be_complete_and_partial_reruns_retain_successful_jobs(self):
        for state in ('pending', 'failed', None):
            self.processing = state
            with self.assertRaises(ValueError):
                self.check()
        self.processing = 'complete'
        self.runs[0]['run_attempt'] = 2
        self.jobs['Analyze (swift)'].update(run_attempt=2, started_at='2026-10-09T21:00:00Z',
                                          completed_at='2026-10-09T21:02:00Z')
        next(entry for entry in self.data if entry['category'] == '/language:swift')['created_at'] = \
            '2026-10-09T21:01:00Z'
        self.check()

    def test_reservation_release_or_replacement_during_lookup_closes_both_gates(self):
        original = self.objects
        for state in ('released', 'abandoned'):
            def finished(path):
                result = original(path)
                if path == f"git/commits/{'c' * 40}":
                    result['message'] = json.dumps({'schema': 1, 'state': state, 'sha': SHA})
                return result
            with patch.object(self, 'objects', side_effect=finished), self.assertRaises(ValueError):
                self.check()
        count = 0

        def replaced(path):
            nonlocal count
            if path == f"git/commits/{'d' * 40}":
                return {'message': json.dumps({'schema': 1, 'state': 'reserved', 'sha': SHA})}
            result = original(path)
            if path == 'git/ref/heads/candidate-reservation':
                count += 1
                if count == 2:
                    result['object']['sha'] = 'd' * 40
            return result

        with patch.object(self, 'objects', side_effect=replaced), self.assertRaises(ValueError):
            self.check()

    def test_total_candidate_budget_bounds_api_reads_and_restores_the_default(self):
        with CHECKS.read_budget(10), patch.object(CHECKS.time, 'monotonic', side_effect=[0, 1]), \
                patch.object(CHECKS.subprocess, 'run', return_value=type('Reply', (), {
                    'returncode': 0, 'stdout': '[{}]'})()) as execute:
            CHECKS.api('fixture')
        self.assertEqual(execute.call_args.kwargs['timeout'], 9)
        self.assertEqual(CHECKS.READ_DEADLINE.get(), float('inf'))
        with CHECKS.read_budget(10), patch.object(CHECKS.time, 'monotonic', side_effect=[0, 10]), \
                patch.object(CHECKS.subprocess, 'run') as execute:
            with self.assertRaisesRegex(ValueError, 'deadline'):
                CHECKS.api('fixture')
        execute.assert_not_called()

    def test_truncated_run_search_and_missing_upload_fail_closed(self):
        original = self.pages

        def truncated(path):
            result = original(path)
            if '/runs?' in path:
                result[0]['total_count'] = 1001
            return result

        with patch.object(self, 'pages', side_effect=truncated), self.assertRaises(ValueError):
            self.check()
        for field in ('id', 'sarif_id'):
            saved = self.data[0].pop(field)
            with self.assertRaises(ValueError):
                self.check()
            self.data[0][field] = saved
