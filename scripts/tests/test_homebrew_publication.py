# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Tap recovery verifies the candidate digest and makes no duplicate metadata commit."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).parents[1]
DMG = b'accepted signed DMG fixture'
TOOL = r'''
import os, pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
cask = root / 'tap/Casks/glimmer.rb'
remote = root / 'remote-cask'
with (root / 'calls').open('a') as log:
    log.write(name + ' ' + ' '.join(args) + '\n')
if name == 'gh':
    assert os.environ['GH_TOKEN'] == 'fixture-read-token'
    if args[1] == 'download':
        (pathlib.Path(args[args.index('-D') + 1]) / 'Glimmer-2026.10.6.dmg').write_bytes(
            b'accepted signed DMG fixture')
    elif '--json' in args:
        print('true')
elif name == 'git':
    args = args[2:]
    if args[0] == 'reset':
        shutil.copyfile(remote, cask)
    elif args[0] == 'rev-parse':
        print('a' * 40)
    elif args[0] == 'diff':
        sys.exit(0 if cask.read_bytes() == remote.read_bytes() else 1)
elif name == 'github_signed_commit.py':
    assert os.environ['GH_TOKEN'] == 'fixture-tap-token'
    shutil.copyfile(cask, remote)
    if os.environ.get('FIXTURE_LOST_RESPONSE'):
        sys.exit(1)
    print('b' * 40)
'''


class TapPublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ('scripts', 'bin', 'tap/.git', 'tap/Casks'):
            (self.root / directory).mkdir(parents=True)
        shutil.copyfile(SCRIPTS / 'homebrew-bump.sh', self.root / 'scripts/homebrew-bump.sh')
        (self.root / 'remote-cask').write_text('cask "glimmer" do\n  version "2026.10.5"\n'
                                             '  sha256 "old"\n  url "old"\n  app "Glimmer.app"\nend\n')
        shutil.copyfile(self.root / 'remote-cask', self.root / 'tap/Casks/glimmer.rb')
        for name in ('bin/git', 'bin/gh', 'scripts/tap_cache.py', 'scripts/github_signed_commit.py'):
            path = self.root / name
            path.write_text(f'#!{sys.executable}\n' + TOOL)
            path.chmod(0o755)
        (self.root / 'bin/python3').symlink_to(sys.executable)
        self.env = {**os.environ, 'PATH': f'{self.root}/bin:/usr/bin:/bin', 'FIXTURE_ROOT': str(self.root),
                    'GITHUB_ACTIONS': 'true', 'GLIMMER_TAP_CACHE': str(self.root / 'tap'),
                    'GH_TOKEN': 'fixture-tap-token', 'RELEASE_READ_TOKEN': 'fixture-read-token',
                    'EXPECTED_DMG_SHA256': hashlib.sha256(DMG).hexdigest()}

    def run_tap(self):
        return subprocess.run(['bash', str(self.root / 'scripts/homebrew-bump.sh'),
                               '2026.10.6', '2026.10.6-rc.1'], env=self.env, capture_output=True, text=True)

    def test_lost_commit_response_recovers_without_rebuild_or_duplicate_write(self):
        self.env['FIXTURE_LOST_RESPONSE'] = '1'
        self.assertNotEqual(self.run_tap().returncode, 0)
        self.env.pop('FIXTURE_LOST_RESPONSE')
        result = self.run_tap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('already current', result.stdout)
        calls = (self.root / 'calls').read_text()
        self.assertEqual(calls.count('github_signed_commit.py'), 1)
        self.assertNotIn('make ', calls)
        self.assertNotIn('codesign ', calls)
        self.assertIn(hashlib.sha256(DMG).hexdigest(), (self.root / 'remote-cask').read_text())

    def test_missing_or_wrong_digest_stops_before_tap_mutation(self):
        original = (self.root / 'remote-cask').read_bytes()
        for value in ('', '0' * 64):
            self.env['EXPECTED_DMG_SHA256'] = value
            result = self.run_tap()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('differs from the verified candidate', result.stderr)
        self.assertEqual((self.root / 'remote-cask').read_bytes(), original)
        self.assertNotIn('github_signed_commit.py', (self.root / 'calls').read_text())


if __name__ == '__main__':
    unittest.main()
