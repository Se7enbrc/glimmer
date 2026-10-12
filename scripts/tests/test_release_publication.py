# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Late publication failures reuse the persisted bytes and never replace assets."""

import copy
import json
import os
import plistlib
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import release_artifact as artifact
import release_publication as publication

SHORT = '2026.10.6'
SHA = 'a' * 40
TAG = SHORT + '-rc.1'


class RetryablePublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.assets = self.root / 'signed'
        self.assets.mkdir()
        self.env = patch.dict(os.environ, GITHUB_REPOSITORY='Se7enbrc/glimmer', GITHUB_RUN_ID='12',
                              GITHUB_RUN_ATTEMPT='1', EXPECTED_SHA=SHA, RC_TAG=TAG,
                              GITHUB_OUTPUT=str(self.root / 'outputs'), RUNNER_TEMP=str(self.root),
                              SIGNED_ATTEMPT='1')
        self.env.start()
        self.addCleanup(self.env.stop)
        for suffix in ('dmg', 'zip', 'intoto.jsonl'):
            (self.assets / f'Glimmer-{SHORT}.{suffix}').write_bytes(b'original signed fixture')
        receipt = {'short': SHORT, 'build': '400', 'length': '23', 'signature': 'fixture', 'public_key': 'fixture'}
        (self.assets / 'release.json').write_text(json.dumps(receipt))
        (self.assets / 'notes.md').write_text('Fixture notes')
        (self.assets / 'CHANGELOG.md').write_text('Fixture changelog')
        (self.assets / 'prerequisites.json').write_text(json.dumps({'sha': SHA, 'runs': []}))
        artifact.seal(self.assets, 'signed')
        os.environ['SIGNED_MANIFEST'] = artifact.digest(self.assets / 'manifest.json')
        version = patch.object(publication, 'version', return_value=(SHORT, '400'))
        version.start()
        self.addCleanup(version.stop)
        self.data = None
        self.calls = []
        self.fail_feed = False
        self.fail_upload = None
        self.feed = '<rss><channel/></rss>'
        commands = patch.object(publication, 'command', side_effect=self.command)
        commands.start()
        self.addCleanup(commands.stop)

    def command(self, args, message, **kwargs):
        self.calls.append(args)
        if args[:3] == ['gh', 'api', '--paginate']:
            return json.dumps([[self.data] if self.data else []])
        if args[:2] == ['gh', 'api']:
            return SHA
        if args[:3] == ['gh', 'release', 'create']:
            self.data = {'id': 1, 'tag_name': TAG, 'draft': True, 'prerelease': True, 'assets': []}
            return ''
        if args[:3] == ['gh', 'release', 'upload']:
            path = Path(args[4])
            if self.fail_upload == path.suffix:
                raise ValueError(message)
            self.data['assets'].append({'name': path.name, 'digest': 'sha256:' + artifact.digest(path),
                                        'state': 'uploaded'})
            return ''
        if args[:3] == ['gh', 'release', 'edit']:
            self.data['draft'] = False
            return ''
        if args[:2] == ['git', 'fetch']:
            return ''
        if args[:2] == ['git', 'rev-parse']:
            return 'b' * 40
        if args[:2] == ['git', 'show']:
            return self.feed
        if args[1] == 'scripts/update-appcast.py':
            Path(args[2]).write_text('updated fixture feed')
            return ''
        if args[1] == 'scripts/github_signed_commit.py':
            if self.fail_feed:
                raise ValueError(message)
            self.feed = Path(args[6]).read_text()
            return 'c' * 40
        raise AssertionError(args)

    def test_late_feed_failure_and_second_attempt_reuse_exact_bytes(self):
        before = {p.name: p.read_bytes() for p in self.assets.iterdir()}
        self.fail_feed = True
        with self.assertRaisesRegex(ValueError, 'retry feed'):
            publication.publish(self.assets)
        self.assertFalse(self.data['draft'])
        self.assertIn('feed pending', (self.root / 'glimmer-publication-state').read_text())
        uploaded = [call for call in self.calls if call[:3] == ['gh', 'release', 'upload']]
        self.assertEqual(len(uploaded), 3)
        self.fail_feed = False
        with patch.dict(os.environ, GITHUB_RUN_ATTEMPT='2'):
            publication.publish(self.assets)
            publication.publish(self.assets)
        self.assertEqual(uploaded, [call for call in self.calls if call[:3] == ['gh', 'release', 'upload']])
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.assets.iterdir()})
        self.assertFalse(any(call[0] in ('make', 'codesign', 'xcodebuild') for call in self.calls))
        self.assertFalse(any('--clobber' in call for call in self.calls))

    def test_partial_upload_retries_only_missing_assets(self):
        self.fail_upload = '.zip'
        with self.assertRaises(ValueError):
            publication.publish(self.assets)
        self.assertTrue(self.data['draft'])
        existing = copy.deepcopy(self.data['assets'])
        self.fail_upload = None
        publication.publish(self.assets)
        for asset in existing:
            self.assertEqual(self.data['assets'].count(asset), 1)
        self.assertEqual(len(self.data['assets']), 3)

    def test_remote_mismatch_unknown_digest_or_incomplete_asset_never_overwrites(self):
        publication.publish(self.assets)
        original = copy.deepcopy(self.data)
        for field, value in [('digest', 'sha256:' + '0' * 64), ('digest', None), ('state', 'new')]:
            self.data = copy.deepcopy(original)
            self.data['assets'][0][field] = value
            self.calls.clear()
            with self.subTest(field=field), self.assertRaises(ValueError):
                publication.publish(self.assets)
            self.assertFalse(any(call[:3] == ['gh', 'release', 'upload'] for call in self.calls))

    def test_tampered_or_other_run_payload_stops_before_any_api_write(self):
        for key, value in [('EXPECTED_SHA', 'b' * 40), ('GITHUB_RUN_ID', '13'), ('SIGNED_ATTEMPT', '2')]:
            with patch.dict(os.environ, {key: value}), self.assertRaises(ValueError):
                publication.publish(self.assets)
        (self.assets / f'Glimmer-{SHORT}.dmg').write_bytes(b'tampered')
        with self.assertRaises(ValueError):
            publication.publish(self.assets)
        self.assertEqual(self.calls, [])

    def test_missing_provenance_and_manifest_fail_closed(self):
        path = self.assets / f'Glimmer-{SHORT}.intoto.jsonl'
        path.unlink()
        with self.assertRaises(ValueError):
            publication.load(self.assets)
        with patch.dict(os.environ, SIGNED_MANIFEST=''):
            with self.assertRaises(ValueError):
                publication.load(self.assets)

    def test_attestation_failure_cannot_seal_final_assets(self):
        (self.assets / 'manifest.json').unlink()
        for value in ('', 'unknown'):
            with patch.dict(os.environ, RELEASE_ATTESTATION_ID=value), self.assertRaises(ValueError):
                publication.persist(self.assets)
        self.assertFalse((self.assets / 'manifest.json').exists())

    def test_api_failure_does_not_mean_release_absent(self):
        with patch.object(publication, 'command', side_effect=ValueError('network failure')):
            with self.assertRaises(ValueError):
                publication.release_data(TAG)


class PublicationPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'Glimmer.app'
        (self.app / 'Contents').mkdir(parents=True)
        self.dist = self.root / 'dist'
        self.dist.mkdir()
        for suffix in ('zip', 'dmg'):
            (self.dist / f'Glimmer-{SHORT}.{suffix}').write_bytes(b'accepted')
        self.info = {'CFBundleShortVersionString': SHORT, 'CFBundleVersion': '400', 'SUPublicEDKey': 'public'}
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        env = patch.dict(os.environ, GITHUB_REPOSITORY='Se7enbrc/glimmer', GITHUB_RUN_ID='12',
                         GITHUB_RUN_ATTEMPT='1', EXPECTED_SHA=SHA, RC_TAG=TAG, RUNNER_TEMP=str(self.root),
                         GITHUB_OUTPUT=str(self.root / 'outputs'), SPARKLE_ED_PRIVATE_KEY='fixture-private-key')
        env.start()
        self.addCleanup(env.stop)
        self.fail_signer = False
        self.signature = 'sparkle:edSignature="YWJj" length="8"'
        self.calls = []
        run = patch.object(publication.subprocess, 'run', side_effect=self.run_command)
        run.start()
        self.addCleanup(run.stop)

    def run_command(self, args, **kwargs):
        self.calls.append((args, kwargs))
        output = ''
        if args[:2] == ['git', 'show']:
            if args[2].endswith('Version.xcconfig'):
                output = f'MARKETING_VERSION = {SHORT}\nCURRENT_PROJECT_VERSION = 400\n'
            elif args[2].endswith('Info.plist'):
                output = plistlib.dumps({'SUPublicEDKey': 'public'}).decode()
            else:
                output = 'Fixture changelog'
        elif args[0] == 'scripts/sparkle-tools.sh':
            output = '/pinned-tools'
        elif args[0] == '/pinned-tools/sign_update':
            if self.fail_signer:
                return subprocess.CompletedProcess(args, 1, 'fixture-private-key', 'fixture-private-key')
            output = self.signature
        elif args[1] == 'scripts/changelog.py':
            output = 'Fixture release notes'
        else:
            raise AssertionError(args)
        return subprocess.CompletedProcess(args, 0, output, '')

    def test_prepare_and_persist_include_provenance_hashes_and_public_metadata_only(self):
        publication.prepare(self.dist, self.app)
        signer = next(call for call in self.calls if call[0][0] == '/pinned-tools/sign_update')
        self.assertEqual(signer[1]['input'], 'fixture-private-key\n')
        self.assertNotIn('fixture-private-key', str(signer[0]))
        provenance = self.root / 'provenance.jsonl'
        provenance.write_text('fixture attestation')
        (self.root / 'glimmer-prerequisites.json').write_text(json.dumps({'sha': SHA, 'runs': []}))
        with patch.dict(os.environ, RELEASE_ATTESTATION_ID='123', RELEASE_PROVENANCE_BUNDLE=str(provenance)):
            publication.persist(self.dist)
        proof = artifact.verify(self.dist, 'signed', artifact.digest(self.dist / 'manifest.json'), '1')
        self.assertIn(f'Glimmer-{SHORT}.intoto.jsonl', proof['hashes'])
        self.assertIn('prerequisites.json', proof['hashes'])
        for path in self.dist.iterdir():
            self.assertNotIn(b'fixture-private-key', path.read_bytes())

    def test_signer_failure_and_bad_length_cannot_prepare_publication(self):
        self.fail_signer = True
        with self.assertRaisesRegex(ValueError, 'update signing failed') as error:
            publication.prepare(self.dist, self.app)
        self.assertNotIn('fixture-private-key', str(error.exception))
        self.fail_signer = False
        self.signature = 'sparkle:edSignature="YWJj" length="9"'
        with self.assertRaisesRegex(ValueError, 'invalid metadata'):
            publication.prepare(self.dist, self.app)
        self.assertFalse((self.dist / 'release.json').exists())

    def test_bundle_version_and_update_key_must_match_reviewed_source_before_signing(self):
        for field, value in [('CFBundleVersion', '399'), ('SUPublicEDKey', 'other')]:
            changed = {**self.info, field: value}
            (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(changed))
            with self.subTest(field=field), self.assertRaises(ValueError):
                publication.prepare(self.dist, self.app)
        self.assertFalse(any(call[0][0] == '/pinned-tools/sign_update' for call in self.calls))


if __name__ == '__main__':
    unittest.main()
