# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Late publication failures reuse the persisted bytes and never replace assets."""

import copy
import json
import os
import plistlib
import shutil
import xml.etree.ElementTree as ET
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
        receipt = {'short': SHORT, 'build': '400', 'length': '23', 'signature': 'fixture', 'public_key': 'fixture',
                   'min_system': '15.7'}
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
        self.tooling = self.root / 'tooling'
        (self.tooling / 'scripts').mkdir(parents=True)
        (self.tooling / 'Glimmer').mkdir()
        for name in ('update-appcast.py', 'release_validation.py', 'changelog.py'):
            shutil.copy2(Path(publication.__file__).parent / name, self.tooling / 'scripts' / name)
        (self.tooling / 'Glimmer/Info.plist').write_bytes(
            plistlib.dumps({'LSMinimumSystemVersion': '26.0'}))
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
            self.data = {'id': 1, 'tag_name': args[3], 'draft': True, 'prerelease': True, 'assets': []}
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
            result = subprocess.run(args, cwd=self.tooling, capture_output=True, text=True)
            if result.returncode:
                raise ValueError(message)
            return result.stdout
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

    def test_candidate_floor_survives_real_feed_publication_and_retry(self):
        app = self.root / 'Glimmer.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': SHORT, 'CFBundleVersion': '400',
            'SUPublicEDKey': 'fixture', 'LSMinimumSystemVersion': '15.7'}))
        source_info = plistlib.dumps({'SUPublicEDKey': 'fixture', 'LSMinimumSystemVersion': '26.0'}).decode()
        with patch.object(publication, 'source_file', side_effect=[source_info, 'Fixture changelog']), \
                patch.object(publication, 'command', side_effect=[
                    '/fixture-tools', 'sparkle:edSignature="YWJj" length="23"', 'Fixture notes']), \
                patch.dict(os.environ, SPARKLE_ED_PRIVATE_KEY='fixture-key'):
            publication.prepare(self.assets, app)
        (self.assets / 'manifest.json').unlink()
        artifact.seal(self.assets, 'signed')
        os.environ['SIGNED_MANIFEST'] = artifact.digest(self.assets / 'manifest.json')
        self.assertEqual(publication.load(self.assets)[0]['min_system'], '15.7')
        publication.publish(self.assets)
        item = ET.fromstring(self.feed).find('channel/item')
        self.assertEqual(item.findtext('{http://www.andymatuschak.org/xml-namespaces/sparkle}'
                                       'minimumSystemVersion'), '15.7')
        original = self.feed
        publication.publish(self.assets)
        self.assertEqual(self.feed, original)
        receipt, _ = publication.load(self.assets)
        with self.assertRaisesRegex(ValueError, 'feed update rejected'):
            publication.publish_feed(self.assets, {**receipt, 'min_system': '26.0'}, TAG)
        self.assertEqual(self.feed, original)

    def test_receipt_floor_must_be_present_and_valid(self):
        path = self.assets / 'release.json'
        receipt = json.loads(path.read_text())
        for value in (None, '', 15.7, '15', '15.7beta', '15.7\n', '0.0'):
            with self.subTest(value=value):
                changed = {**receipt, 'min_system': value}
                if value is None:
                    changed.pop('min_system')
                path.write_text(json.dumps(changed))
                (self.assets / 'manifest.json').unlink()
                artifact.seal(self.assets, 'signed')
                os.environ['SIGNED_MANIFEST'] = artifact.digest(self.assets / 'manifest.json')
                with self.assertRaisesRegex(ValueError, 'minimum system version'):
                    publication.load(self.assets)

    def test_distribution_validation_compares_receipt_floor_with_extracted_app(self):
        def extract(args, message, **kwargs):
            if args[0] == 'ditto':
                path = Path(args[-1]) / 'Glimmer.app/Contents/Info.plist'
                path.parent.mkdir(parents=True)
                path.write_bytes(plistlib.dumps({'CFBundleShortVersionString': SHORT,
                                                'CFBundleVersion': '400', 'LSMinimumSystemVersion': floor}))
            return ''
        with patch.object(publication, 'command', side_effect=extract), \
                patch.object(publication, 'validate_distribution') as distribution:
            floor = '26.0'
            with self.assertRaisesRegex(ValueError, 'minimum system version'):
                publication.validate(self.assets)
            distribution.assert_not_called()
            floor = '15.7'
            publication.validate(self.assets)
            distribution.assert_called_once()

    def test_diagnostic_publication_is_manual_only_and_retries_the_same_symbol_assets(self):
        os.environ['RC_TAG'] = TAG + '-diag'
        archive = f'Glimmer-{SHORT}-symbols.zip'
        (self.assets / archive).write_bytes(b'diagnostic symbols')
        record = {'identity': artifact.identity(), 'sha256': artifact.digest(self.assets / archive),
                  'images': {'Glimmer': {'uuids': []}, 'GlimmerEngine': {'uuids': []}}}
        (self.assets / 'symbols.json').write_text(json.dumps(record))
        receipt = json.loads((self.assets / 'release.json').read_text())
        receipt['diagnostic_symbols'] = {'archive': archive, **record}
        (self.assets / 'release.json').write_text(json.dumps(receipt))
        (self.assets / 'manifest.json').unlink()
        artifact.seal(self.assets, 'signed')
        os.environ['SIGNED_MANIFEST'] = artifact.digest(self.assets / 'manifest.json')
        publication.publish(self.assets)
        publication.publish(self.assets)
        self.assertFalse(any(call[:2] == ['git', 'fetch'] for call in self.calls))
        self.assertFalse(any('scripts/update-appcast.py' in call for call in self.calls))
        self.assertEqual(sum(call[:3] == ['gh', 'release', 'upload'] for call in self.calls), 5)
        create = next(call for call in self.calls if call[:3] == ['gh', 'release', 'create'])
        self.assertIn('Diagnostic', create[create.index('--title') + 1])
        self.assertIn('manual installation only', (self.root / 'glimmer-publication-state').read_text())
        with self.assertRaisesRegex(ValueError, 'never enter'):
            publication.publish_feed(self.assets, receipt, TAG + '-diag')

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

    def test_new_draft_listing_lag_retries_without_recreating(self):
        lookup = publication.release_data
        reads = 0

        def lagged(tag):
            nonlocal reads
            reads += 1
            return None if reads <= 3 else lookup(tag)

        with patch.object(publication, 'release_data', side_effect=lagged), \
                patch.object(publication, 'time') as clock:
            publication.publish(self.assets)
        self.assertEqual([call.args[0] for call in clock.sleep.call_args_list], [0.25, 0.5])
        self.assertEqual(sum(call[:3] == ['gh', 'release', 'create'] for call in self.calls), 1)
        self.assertFalse(self.data['draft'])

    def test_missing_created_draft_reports_visibility_not_stability(self):
        with patch.object(publication, 'release_data', return_value=None), \
                patch.object(publication, 'time') as clock:
            with self.assertRaisesRegex(ValueError, 'not visible.*retry publication'):
                publication.publish(self.assets)
        self.assertEqual(clock.sleep.call_count, 3)
        self.assertFalse(any(call[:3] == ['gh', 'release', 'upload'] for call in self.calls))

    def test_genuine_stable_release_requires_promotion_recovery_without_writes(self):
        self.data = {'id': 1, 'tag_name': TAG, 'draft': False, 'prerelease': False, 'assets': []}
        with self.assertRaisesRegex(ValueError, 'already stable; use promotion recovery'):
            publication.publish(self.assets)
        self.assertFalse(any(call[:2] == ['gh', 'release'] for call in self.calls))

    def test_lookup_service_failure_is_not_retried_as_visibility_lag(self):
        with patch.object(publication, 'release_data', side_effect=ValueError('service failure')), \
                patch.object(publication, 'time') as clock:
            with self.assertRaisesRegex(ValueError, 'service failure'):
                publication.await_release(TAG)
        clock.sleep.assert_not_called()


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
        self.info = {'CFBundleShortVersionString': SHORT, 'CFBundleVersion': '400', 'SUPublicEDKey': 'public',
                     'LSMinimumSystemVersion': '15.7'}
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
        self.assertEqual(json.loads((self.dist / 'release.json').read_text())['min_system'], '15.7')
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

    def test_candidate_floor_is_validated_before_signing(self):
        for value in (None, '', 15.7, '15.7beta'):
            with self.subTest(value=value):
                info = {**self.info, 'LSMinimumSystemVersion': value}
                if value is None:
                    info.pop('LSMinimumSystemVersion')
                (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                with self.assertRaisesRegex(ValueError, 'minimum system version'):
                    publication.prepare(self.dist, self.app)
        self.assertFalse(any(call[0][0] == '/pinned-tools/sign_update' for call in self.calls))

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

    def test_diagnostic_marker_cannot_be_published_under_an_ordinary_tag(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(
            {**self.info, 'GlimmerDiagnosticBuild': 'YES'}))
        with self.assertRaisesRegex(ValueError, 'diagnostic marker'):
            publication.prepare(self.dist, self.app)
        self.assertFalse(any(call[0][0] == '/pinned-tools/sign_update' for call in self.calls))

    def test_diagnostic_preparation_marks_notes_and_carries_symbol_receipt(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(
            {**self.info, 'GlimmerDiagnosticBuild': 'YES'}))
        symbol_receipt = {'archive': f'Glimmer-{SHORT}-symbols.zip', 'sha256': 'a' * 64}
        with patch.dict(os.environ, RC_TAG=TAG + '-diag'), \
                patch.object(publication.release_symbols, 'carry', return_value=symbol_receipt) as carry:
            publication.prepare(self.dist, self.app)
        self.assertEqual(carry.call_count, 1)
        receipt = json.loads((self.dist / 'release.json').read_text())
        self.assertEqual(receipt['diagnostic_symbols'], symbol_receipt)
        self.assertIn('manual installation only', (self.dist / 'notes.md').read_text())
        self.assertIn('symbols-path=', (self.root / 'outputs').read_text())


if __name__ == '__main__':
    unittest.main()
