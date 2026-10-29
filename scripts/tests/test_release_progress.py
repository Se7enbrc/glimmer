# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Release waits report progress independently of blocking subprocesses."""

from contextlib import nullcontext, redirect_stderr
import io
import json
from pathlib import Path
import subprocess
import sys
from unittest.mock import Mock, call, patch

from fixture_git import FixtureTestCase
from test_candidate_prepare import CUTTER, SHA
from test_release_checks import CHECKS

sys.path.insert(0, str(Path(__file__).parents[1]))
import candidate_reservation as reservation
import release_progress as progress


class ReleaseProgressTests(FixtureTestCase):
    def test_start_heartbeat_and_end_are_timestamped_and_flushed(self):
        stopped = Mock()
        stopped.wait.side_effect = [False, True]
        with patch.object(progress, 'Event', return_value=stopped), \
                patch.object(progress, 'monotonic', return_value=0), patch('builtins.print') as output:
            with progress.progress('Verify https://example.test/run/1', 120):
                pass
        messages = [item.args[0] for item in output.call_args_list]
        self.assertIn('Starting: Verify https://example.test/run/1 (timeout 120s)', messages[0])
        self.assertTrue(any('Waiting: Verify https://example.test/run/1' in message for message in messages))
        self.assertIn('Completed: Verify https://example.test/run/1', messages[-1])
        for item in output.call_args_list:
            self.assertRegex(item.args[0], r'^\[\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\] ')
            self.assertEqual(item.kwargs, {'file': sys.stderr, 'flush': True})
        stopped.wait.assert_has_calls([call(60), call(60)])
        stopped.set.assert_called_once()

    def test_failure_and_timeout_have_end_lines(self):
        for error in (ValueError('failed'), subprocess.TimeoutExpired('git', 300)):
            output = io.StringIO()
            with self.subTest(error=error), redirect_stderr(output):
                with self.assertRaises(type(error)), progress.progress('reservation git push', 300):
                    raise error
            self.assertIn('Starting: reservation git push (timeout 300s)', output.getvalue())
            self.assertIn('Ended: reservation git push (failed or interrupted', output.getvalue())
            self.assertNotIn('Completed:', output.getvalue())

    def test_details_identify_the_pending_run_and_reservation_commands_are_visible(self):
        output = io.StringIO()
        with redirect_stderr(output), patch.object(reservation.subprocess, 'run', return_value=Mock(
                returncode=0, stdout='refs')):
            with progress.progress('candidate checks', 2700) as update:
                update('waiting for https://github.com/Se7enbrc/glimmer/actions/runs/42')
            reservation.git('push', '--atomic', 'origin')
        self.assertIn('waiting for https://github.com/Se7enbrc/glimmer/actions/runs/42', output.getvalue())
        self.assertIn('Starting: reservation git push:', output.getvalue())
        self.assertIn('Completed: reservation git push:', output.getvalue())

    def test_admission_start_and_end_include_delivery_and_controller_urls(self):
        output = io.StringIO()
        with redirect_stderr(output), patch.dict(reservation.os.environ, {'GITHUB_RUN_ID': '42'}), \
                patch.object(reservation, 'require'), patch.object(reservation.time, 'monotonic', return_value=0):
            reservation.wait(SHA, Mock(), lambda _: nullcontext())
        for text in ('Starting: delivery admission', 'timeout 1200s', 'Completed: delivery admission',
                     '/actions/runs/42', '/actions/workflows/candidate-delivery.yml'):
            self.assertIn(text, output.getvalue())

    def test_candidate_checks_name_runs_and_report_failure_end(self):
        output = io.StringIO()
        with redirect_stderr(output), patch.object(CUTTER.candidate_reservation, 'reserve', return_value=False), \
                patch.object(CUTTER, 'candidate_runs', return_value=[{'id': 42}]), \
                patch.object(CUTTER.CHECKS, 'check', side_effect=ValueError('failed attempt')):
            with self.assertRaisesRegex(ValueError, 'failed attempt'):
                CUTTER.prepare_candidate(SHA, False)
        for text in ('Starting: candidate Verify and CodeQL', 'timeout 2700s',
                     '/actions/runs/42', 'Ended: candidate Verify and CodeQL'):
            self.assertIn(text, output.getvalue())

    def test_hosted_readiness_gate_has_progress_and_a_total_api_budget(self):
        output = io.StringIO()
        with redirect_stderr(output), patch.object(sys, 'argv', ['release-checks.py', SHA]), \
                patch.dict(CHECKS.os.environ, {}, clear=True), patch.object(CHECKS.time, 'monotonic', return_value=0), \
                patch.object(CHECKS, 'read_budget', return_value=nullcontext()) as budget, \
                patch.object(CHECKS, 'check'):
            CHECKS.main()
        budget.assert_called_once_with(600)
        for text in ('Starting: required checks', 'timeout 600s', 'Completed: required checks', f'/commit/{SHA}/checks'):
            self.assertIn(text, output.getvalue())


class ReleaseWaitDeadlineTests(FixtureTestCase):
    def test_discovery_uses_elapsed_time_and_bounds_each_lookup(self):
        output = io.StringIO()
        now = [0]
        def lookup(sha, timeout):
            self.assertEqual(timeout, 60)
            now[0] = 60
            return [{'databaseId': 42, 'url': 'https://example.test/42'}]
        with redirect_stderr(output), patch.object(CUTTER.time, 'monotonic', side_effect=lambda: now[0]), \
                patch.object(CUTTER, 'release_runs', side_effect=lookup) as runs, \
                patch.object(CUTTER, 'show') as show, patch.object(CUTTER.time, 'sleep') as sleep:
            with self.assertRaisesRegex(ValueError, 'timed out'):
                CUTTER.wait_for_release(SHA, set())
        runs.assert_called_once()
        show.assert_not_called()
        sleep.assert_not_called()
        self.assertIn('Starting: Release dispatch', output.getvalue())
        self.assertIn('timeout 60s', output.getvalue())
        self.assertIn('Ended: Release dispatch', output.getvalue())

    def test_discovery_success_ends_before_opening_or_commenting_the_run(self):
        output = io.StringIO()
        with redirect_stderr(output), patch.object(CUTTER.time, 'monotonic', return_value=0), \
                patch.object(CUTTER, 'release_runs', return_value=[{'databaseId': 42, 'url': 'https://example.test/42'}]), \
                patch.object(CUTTER, 'show') as show:
            self.assertEqual(CUTTER.wait_for_release(SHA, {41}), 'https://example.test/42')
        show.assert_not_called()
        self.assertIn('Completed: Release dispatch', output.getvalue())

    def test_integration_timeout_cannot_accept_late_success(self):
        now = [0]
        def check(*args, **kwargs):
            self.assertEqual(kwargs['timeout'], 600)
            now[0] = CUTTER.TIMEOUT_SECONDS
            return Mock(returncode=0)
        with patch.object(CUTTER.time, 'monotonic', side_effect=lambda: now[0]), \
                patch.object(CUTTER, 'checks_pending', return_value=True), \
                patch.object(CUTTER.subprocess, 'run', side_effect=check), \
                patch.object(CUTTER.time, 'sleep') as sleep:
            with self.assertRaisesRegex(ValueError, 'timed out'):
                CUTTER.wait_for_checks(SHA, False)
        sleep.assert_not_called()

    def test_integration_start_pending_run_dry_run_and_end_messages(self):
        output = io.StringIO()
        pages = [{'check_runs': [{'id': 1, 'name': 'macOS', 'status': 'in_progress',
                                  'details_url': 'https://github.com/Se7enbrc/glimmer/actions/runs/42'}]}]
        with redirect_stderr(output), patch.object(CUTTER, 'output', return_value=json.dumps(pages)), \
                patch.object(CUTTER.subprocess, 'run', return_value=Mock(returncode=1, stderr='ERR: pending')):
            CUTTER.wait_for_checks(SHA, True)
        for text in ('Starting: integration checks', 'timeout 5400s', 'macOS: in_progress',
                     '/actions/runs/42', 'would wait up to 90 min', 'Completed: integration checks'):
            self.assertIn(text, output.getvalue())
