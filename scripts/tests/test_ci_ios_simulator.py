# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Simulator destinations follow the selected Xcode SDK, not inventory order."""

import json
import os
from pathlib import Path
import subprocess
import tempfile

from fixture_git import FixtureTestCase

ROOT = Path(__file__).resolve().parents[2]


class IOSSimulatorSelectionTests(FixtureTestCase):
    def test_selects_matching_runtime_and_exact_device_type(self):
        result, calls = self.run_helper(existing=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'platform=iOS Simulator,id=matching-phone')
        self.assertFalse(any('create' in call or '-downloadPlatform' in call for call in calls))

    def test_creates_on_matching_runtime_instead_of_reusing_newer_phone(self):
        result, calls = self.run_helper(existing=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'platform=iOS Simulator,id=created-phone')
        self.assertIn(['simctl', 'create', 'Glimmer CI iPhone',
                       'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',
                       'com.apple.CoreSimulator.SimRuntime.iOS-26-5'], calls)

    def test_download_failure_never_falls_back_to_an_unrelated_runtime(self):
        result, calls = self.run_helper(existing=False, compatible=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(['-downloadPlatform', 'iOS'], calls)
        self.assertFalse(any('create' in call for call in calls))

    def run_helper(self, *, existing, compatible=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtimes = [{'platform': 'iOS', 'isAvailable': True, 'version': version,
                         'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-' + version.replace('.', '-')}
                        for version in (['27.1', '26.5'] if compatible else ['27.1'])]
            kind = 'com.apple.CoreSimulator.SimDeviceType.'
            phone = lambda name, identifier, model: {'name': name, 'udid': identifier,
                                                     'deviceTypeIdentifier': kind + model}
            devices = {'com.apple.CoreSimulator.SimRuntime.iOS-27-1': [phone('iPhone Duo', 'wrong-runtime', 'iPhone-17-Pro')],
                       'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [phone('iPhone 16', 'wrong-model', 'iPhone-16')]}
            if existing:
                devices['com.apple.CoreSimulator.SimRuntime.iOS-26-5'].append(
                    phone('Renamed test device', 'matching-phone', 'iPhone-17-Pro'))
            inventory = root / 'inventory.json'
            inventory.write_text(json.dumps({'runtimes': runtimes, 'devices': devices}))
            stub = '''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ['SIMULATOR_FIXTURE'])
with (root / 'calls.jsonl').open('a') as output: output.write(json.dumps(args) + '\\n')
if args == ['--sdk', 'iphonesimulator', '--show-sdk-version']: print('26.5')
elif args[:3] == ['simctl', 'list', 'runtimes']: print((root / 'inventory.json').read_text())
elif args[:3] == ['simctl', 'list', 'devices']: print((root / 'inventory.json').read_text())
elif args[:2] == ['simctl', 'create']: print('created-phone')
elif args == ['-version']: print('Xcode 26.6')
elif args == ['-downloadPlatform', 'iOS']: sys.exit(1)
else: raise SystemExit('unexpected command: ' + repr(args))
'''
            for tool in ['xcrun', 'xcodebuild']:
                path = root / tool
                path.write_text(stub)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'], SIMULATOR_FIXTURE=str(root))
            result = subprocess.run(['bash', str(ROOT / 'scripts/ci-ios-simulator.sh')], env=env,
                                    capture_output=True, text=True, timeout=20)
            calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
            return result, calls
