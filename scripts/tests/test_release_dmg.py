# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""DMG signing and validation use inert commands, never a real signing identity."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_publication as publication

TOOL = r'''
import json, os, pathlib, sys
args = [pathlib.Path(sys.argv[0]).name, *sys.argv[1:]]
with open(os.environ['DMG_TEST_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\n')
if os.environ.get('DMG_TEST_FAIL') == ' '.join(args[:3]):
    sys.exit(1)
if args[:3] == ['xcrun', 'notarytool', 'submit']:
    print(json.dumps({'status': os.environ.get('DMG_TEST_STATUS', 'Accepted')}))
'''


class DmgSigningTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='glimmer dmg fixture ')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.log = self.root / 'calls.jsonl'
        self.dmg = self.root / 'Glimmer-fixture.dmg'
        self.dmg.write_bytes(b'inert disk image')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('codesign', 'xcrun'):
            path = self.bin / name
            path.write_text(f'#!{sys.executable}\n' + TOOL)
            path.chmod(0o755)
        (self.bin / 'python3').symlink_to(sys.executable)
        recipe = Path(__file__).resolve().parents[1] / 'release-bundle.mk'
        (self.root / 'Makefile').write_text(
            f'include {recipe}\n.PHONY: ensure-signing\nensure-signing:\n\t@true\n')
        self.env = {'PATH': f'{self.bin}:/usr/bin:/bin', 'HOME': str(self.root),
                    'DMG_TEST_LOG': str(self.log)}

    def run_sign(self, identity='Developer ID Application: Fixture'):
        return subprocess.run(['/usr/bin/make', 'notarize-dmg', f'DIST_DIR={self.root}',
                               f'DMG_NAME={self.dmg.name}', f'DERIVED={self.root}',
                               f'DEVELOPER_ID={identity}', 'SIGN_KEYCHAIN=fixture keychain',
                               'NOTARY_PROFILE=fixture profile'], cwd=self.root, env=self.env,
                              capture_output=True, text=True, timeout=10)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_timestamped_identity_then_submission_then_staple(self):
        result = self.run_sign()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [
            ['codesign', '--force', '--timestamp', '--sign', 'Developer ID Application: Fixture',
             '--keychain', 'fixture keychain', '--identifier', 'io.ugfugl.Glimmer.dmg', str(self.dmg)],
            ['xcrun', 'notarytool', 'submit', str(self.dmg), '--keychain-profile', 'fixture profile',
             '--keychain', 'fixture keychain', '--wait', '--output-format', 'json'],
            ['xcrun', 'stapler', 'staple', str(self.dmg)]])

    def test_failed_sign_submit_or_staple_fails_closed(self):
        for failed, count in (('codesign --force --timestamp', 1), ('xcrun notarytool submit', 2),
                              ('xcrun stapler staple', 3)):
            with self.subTest(failed=failed):
                self.log.unlink(missing_ok=True)
                self.env['DMG_TEST_FAIL'] = failed
                self.assertNotEqual(self.run_sign().returncode, 0)
                self.assertEqual(len(self.calls()), count)

    def test_nonaccepted_submission_never_staples(self):
        for status in ('Invalid', 'In Progress', ''):
            with self.subTest(status=status):
                self.log.unlink(missing_ok=True)
                self.env['DMG_TEST_STATUS'] = status
                self.assertNotEqual(self.run_sign().returncode, 0)
                self.assertEqual(len(self.calls()), 2)

    def test_missing_dmg_or_identity_cannot_sign(self):
        for identity in ('', '-'):
            with self.subTest(identity=identity):
                self.assertNotEqual(self.run_sign(identity).returncode, 0)
                self.assertEqual(self.calls(), [])
        self.dmg.unlink()
        self.assertNotEqual(self.run_sign().returncode, 0)
        self.assertEqual(self.calls(), [])


class DmgValidationTests(unittest.TestCase):
    def test_each_dmg_check_gates_zip_validation(self):
        root = Path('/inert fixture')
        dmg = str(root / 'Glimmer-2026.10.9.dmg')
        checks = [(['codesign', '--verify', '--strict', '--verbose=2', dmg], 'DMG signature rejected'),
                  (['spctl', '-a', '-t', 'open', '--context', 'context:primary-signature',
                    '--verbose=2', dmg], 'DMG Gatekeeper assessment rejected'),
                  (['xcrun', 'stapler', 'validate', dmg], 'DMG notarization ticket rejected')]
        for failed, (expected, message) in enumerate(checks):
            with self.subTest(check=expected), \
                    patch.object(publication, 'load', return_value=({'short': '2026.10.9'}, {})), \
                    patch.object(publication.subprocess, 'run') as run:
                run.side_effect = [subprocess.CompletedProcess(args, int(index == failed), '', '')
                                   for index, (args, _) in enumerate(checks[:failed + 1])]
                with self.assertRaisesRegex(ValueError, message):
                    publication.validate(root)
                self.assertEqual([call.args[0] for call in run.call_args_list],
                                 [args for args, _ in checks[:failed + 1]])


if __name__ == '__main__':
    unittest.main()
