# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Only trusted API identities admit deliveries or retire their durable claims."""

import copy
import subprocess
import tempfile
from pathlib import Path
import unittest

from fixture_git import FixtureTestCase
import sys
from unittest.mock import Mock, patch
sys.path.insert(0, str(Path(__file__).parents[1]))
import candidate_delivery as controller

SHA = 'a' * 40
RUN = {'id': 10, 'run_attempt': 2, 'head_sha': SHA, 'head_branch': 'release-candidate',
       'path': '.github/workflows/release.yml', 'workflow_id': 7, 'event': 'workflow_dispatch',
       'head_repository': {'full_name': 'Se7enbrc/glimmer'}, 'status': 'in_progress'}


class DeliveryControllerTests(FixtureTestCase):
    def setUp(self):
        self.run = copy.deepcopy(RUN)
        self.current = copy.deepcopy(RUN)
        self.checks = Mock(REPO='Se7enbrc/glimmer')
        self.checks.object_api.side_effect = self.objects
        snapshot = patch.object(controller.reservation, 'snapshot', return_value=(
            {}, {'sha': SHA, 'state': 'reserved', 'claims': {}}))
        snapshot.start()
        self.addCleanup(snapshot.stop)
        for name in ('admit', 'depart'):
            mock = patch.object(controller.reservation, name)
            setattr(self, name, mock.start())
            self.addCleanup(mock.stop)

    def objects(self, path):
        if path == 'actions/runs/10/attempts/2':
            return self.run
        if path == 'actions/runs/10':
            return self.current
        if path.startswith('actions/workflows/'):
            return {'id': 7, 'path': RUN['path'], 'state': 'active'}
        raise AssertionError(path)

    def test_current_attempt_is_admitted_and_only_completed_attempt_releases_its_claim(self):
        controller.sync(10, 2, self.checks)
        identity = self.admit.call_args.args[1]
        self.assertEqual(identity, {'run': 10, 'attempt': 2, 'sha': SHA,
                                    'ref': 'refs/heads/release-candidate', 'workflow': RUN['path']})
        self.depart.assert_not_called()
        self.admit.reset_mock()
        self.run['status'] = 'completed'
        self.current['run_attempt'] = 3
        controller.sync(10, 2, self.checks)
        self.depart.assert_called_once_with(SHA, identity)
        self.admit.assert_not_called()

    def test_stale_attempt_fork_wrong_workflow_ref_or_lookup_failure_cannot_admit(self):
        for changes in ({'run_attempt': 1}, {'head_repository': {'full_name': 'fork/glimmer'}},
                        {'path': '.github/workflows/untrusted.yml'}, {'head_branch': 'feature'},
                        {'workflow_id': 99}, {'event': 'pull_request'}, {'head_sha': 'bad'}):
            with self.subTest(changes=changes):
                self.run = {**copy.deepcopy(RUN), **changes}
                with self.assertRaises(ValueError):
                    controller.sync(10, 2, self.checks)
        self.run = copy.deepcopy(RUN)
        for changes in ({'run_attempt': 3}, {'head_sha': 'b' * 40}, {'status': 'completed'},
                        {'status': 'unknown'}):
            self.current = {**copy.deepcopy(RUN), **changes}
            with self.subTest(current=changes), self.assertRaises(ValueError):
                controller.sync(10, 2, self.checks)
        self.checks.object_api.side_effect = ValueError('lookup failed')
        with self.assertRaises(ValueError):
            controller.sync(10, 2, self.checks)
        self.admit.assert_not_called()
        self.depart.assert_not_called()

    def test_context_and_workflows_keep_reservation_writes_out_of_candidate_builds(self):
        env = {'GITHUB_REPOSITORY': 'Se7enbrc/glimmer', 'GITHUB_REF': 'refs/heads/main',
               'GITHUB_EVENT_NAME': 'workflow_run', 'GITHUB_WORKFLOW_REF':
               'Se7enbrc/glimmer/.github/workflows/candidate-delivery.yml@refs/heads/main'}
        with patch.dict(controller.os.environ, env, clear=True):
            controller.controller_context()
            for key, value in [('GITHUB_REF', 'refs/heads/release-candidate'),
                               ('GITHUB_EVENT_NAME', 'pull_request_target'),
                               ('GITHUB_WORKFLOW_REF', 'other'), ('GITHUB_REPOSITORY', 'fork/glimmer')]:
                with patch.dict(controller.os.environ, {key: value}), self.assertRaises(ValueError):
                    controller.controller_context()
        workflows = Path(__file__).parents[2] / '.github/workflows'
        control = (workflows / 'candidate-delivery.yml').read_text()
        self.assertIn('types: [requested, in_progress, completed]', control)
        self.assertIn('environment: rc-cut', control)
        self.assertIn('ref: ${{ github.sha }}', control)
        self.assertNotIn('download-artifact', control)
        self.assertNotIn('permission-workflows: write', control)
        self.assertLess(control.index('Require trusted main'), control.index('secrets.GLIMMER_RC_APP'))
        for name in ('release.yml', 'ios-testflight.yml'):
            workflow = (workflows / name).read_text()
            self.assertIn('candidate_reservation.py wait', workflow)
            self.assertNotIn('candidate_delivery.py', workflow)
        builder = (workflows / 'ios-testflight-build.yml').read_text()
        self.assertNotIn('contents: write', builder)
        self.assertNotIn('GLIMMER_RC_APP', builder)

    def test_mac_checks_require_admission_and_fail_closed_for_candidate_and_promotion(self):
        source = (Path(__file__).parents[1] / 'ci-release.sh').read_text()
        phase = source.split('    checks)\n', 1)[1].split('        ;;', 1)[0]
        shell = '''set -euo pipefail
check_source() { :; }
python3() {
    printf '%s\\n' "$*" >> "$CALLS"
    if [[ " $* " = *" --candidate "* ]] && [ "$DENY_CANDIDATE" = true ]; then
        return 1
    fi
}
''' + phase
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            green, calls = root / 'green', root / 'calls'
            env = {'PATH': '/usr/bin:/bin', 'RUNNER_TEMP': directory, 'GREEN': str(green),
                   'CALLS': str(calls), 'EXPECTED_SHA': SHA, 'CANDIDATE_SHA': 'b' * 40}
            for operation in ('candidate', 'promote'):
                for denied in ('false', 'true'):
                    calls.write_text('')
                    green.write_text('stale authorization')
                    result = subprocess.run(['/bin/bash', '-c', shell], capture_output=True, text=True,
                                            env={**env, 'OPERATION': operation, 'DENY_CANDIDATE': denied})
                    self.assertEqual(result.returncode == 0, denied == 'false', result.stderr)
                    self.assertEqual(green.exists(), denied == 'false')
                    expected = [f'scripts/release-checks.py {SHA} --candidate --delivery']
                    if operation == 'promote':
                        expected = [f'scripts/release-checks.py {SHA}',
                                    'scripts/release-checks.py ' + 'b' * 40 + ' --candidate --delivery']
                    self.assertEqual(calls.read_text().splitlines(), expected)
