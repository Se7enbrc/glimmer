# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Inert TestFlight trust, signing-policy and artifact regression fixtures."""

import copy
from datetime import datetime, timedelta
import importlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
artifact = importlib.import_module('ios-testflight-artifact')
signing = importlib.import_module('ios-testflight-sign')
cli = importlib.import_module('ios-testflight')

ENV = {
    'GITHUB_REPOSITORY': 'Se7enbrc/glimmer', 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '2',
    'EXPECTED_SHA': 'a' * 40, 'TRUSTED_TOOLING_SHA': 'b' * 40, 'GITHUB_SHA': 'b' * 40,
    'IOS_VERSION': '0.1.1', 'IOS_BUILD_NUMBER': '3', 'GITHUB_REF': 'refs/heads/main',
    'GITHUB_EVENT_NAME': 'workflow_dispatch',
    'GITHUB_WORKFLOW_REF': 'Se7enbrc/glimmer/.github/workflows/ios-testflight.yml@refs/heads/main',
}
UUIDS = [('AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA', 'arm64')]


class TestFlightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.expected = artifact.identity(ENV)

    def fixture(self):
        root = self.root / 'Glimmer.xcarchive'
        app = root / artifact.APP
        app.mkdir(parents=True)
        info = {'CFBundleIdentifier': artifact.BUNDLE, 'CFBundleExecutable': 'Glimmer',
                'CFBundleShortVersionString': '0.1.1', 'CFBundleVersion': '3',
                'CFBundleSupportedPlatforms': ['iPhoneOS']}
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        (app / 'Glimmer').write_bytes(b'inert executable fixture')
        (app / 'Glimmer').chmod(0o755)
        privacy = {'NSPrivacyTracking': False, 'NSPrivacyTrackingDomains': [], 'NSPrivacyCollectedDataTypes': [],
                   'NSPrivacyAccessedAPITypes': [
                       {'NSPrivacyAccessedAPIType': f'NSPrivacyAccessedAPICategory{category}',
                        'NSPrivacyAccessedAPITypeReasons': ['fixture']}
                       for category in ('UserDefaults', 'SystemBootTime', 'FileTimestamp')]}
        (app / 'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps(privacy))
        (root / 'Info.plist').write_bytes(plistlib.dumps({
            'ApplicationProperties': {**info, 'ApplicationPath': 'Applications/Glimmer.app'}}))
        symbols = root / 'dSYMs/Glimmer.app.dSYM/Contents/Resources/DWARF'
        symbols.mkdir(parents=True)
        (symbols / 'Glimmer').write_bytes(b'inert symbols fixture')
        return root

    def test_apple_version_and_build_inputs(self):
        for build in ('1', '9999', '3.99', '3.99.99'):
            artifact.validate_inputs('a' * 40, '0.1.1', build)
        for sha, version, build in [('a' * 39, '0.1.1', '3'), ('A' * 40, '0.1.1', '3'),
                                    ('a' * 40, '1; touch bad', '3'), ('a' * 40, '0.1.1', '10000'),
                                    ('a' * 40, '0.1.1', '3.100'), ('a' * 40, '0.1.1', '3.1.100'),
                                    ('a' * 40, '0.1.1', '0'), ('a' * 40, '0.1.1', '03')]:
            with self.subTest(build=build, version=version), self.assertRaises(ValueError):
                artifact.validate_inputs(sha, version, build)

    def test_only_main_manual_workflow_can_access_distribution(self):
        artifact.require_dispatch(ENV)
        for name, value in {'GITHUB_REF': 'refs/heads/untrusted', 'GITHUB_EVENT_NAME': 'pull_request',
                            'GITHUB_REPOSITORY': 'fork/glimmer', 'GITHUB_SHA': 'c' * 40,
                            'GITHUB_WORKFLOW_REF': 'Se7enbrc/glimmer/other.yml@refs/heads/main',
                            'ACTIONS_STEP_DEBUG': 'true', 'RUNNER_DEBUG': '1'}.items():
            with self.subTest(name=name), self.assertRaises(ValueError):
                artifact.require_dispatch({**ENV, name: value})

    def test_gate_reuses_exact_commit_checks_and_propagates_failure(self):
        checks = importlib.import_module('release-checks')
        with patch.dict(os.environ, {**ENV, 'RUNNER_TEMP': str(self.root)}, clear=True):
            with patch.object(checks, 'check', return_value={'sha': ENV['EXPECTED_SHA'], 'runs': []}) as check:
                cli.gate(self.expected)
                check.assert_called_once_with(ENV['EXPECTED_SHA'])
            with patch.object(checks, 'check', side_effect=ValueError('checks not green')):
                with self.assertRaisesRegex(ValueError, 'checks not green'):
                    cli.gate(self.expected)

    def test_handoff_roundtrip_preserves_executable_symbols_and_identity(self):
        root = self.fixture()
        payload = self.root / 'payload'
        with patch.object(artifact, 'uuids', return_value=UUIDS):
            manifest = artifact.seal(root, payload, self.expected)
            restored = artifact.import_archive(payload, self.root / 'restored', self.expected, manifest)
        self.assertEqual((restored / artifact.APP / 'Glimmer').stat().st_mode & 0o777, 0o755)
        self.assertEqual((restored / artifact.APP / 'PrivacyInfo.xcprivacy').read_bytes(),
                         (root / artifact.APP / 'PrivacyInfo.xcprivacy').read_bytes())
        self.assertTrue((restored / 'dSYMs/Glimmer.app.dSYM/Contents/Resources/DWARF/Glimmer').is_file())

    def test_handoff_rejects_other_source_and_tampered_bytes(self):
        root = self.fixture()
        payload = self.root / 'payload'
        with patch.object(artifact, 'uuids', return_value=UUIDS):
            manifest = artifact.seal(root, payload, self.expected)
            with self.assertRaisesRegex(ValueError, 'identity'):
                artifact.import_archive(payload, self.root / 'wrong', {**self.expected, 'EXPECTED_SHA': 'c' * 40}, manifest)
            (payload / 'archive.zip').write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'digest'):
                artifact.import_archive(payload, self.root / 'tampered', self.expected, manifest)

    def test_archive_rejects_wrong_app_identity_and_missing_privacy_manifest(self):
        root = self.fixture()
        app = root / artifact.APP
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        info['CFBundleIdentifier'] = 'unexpected.app'
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, 'identity'):
            artifact.validate_archive(root, self.expected, check_symbols=False)
        info['CFBundleIdentifier'] = artifact.BUNDLE
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        (app / 'PrivacyInfo.xcprivacy').unlink()
        with self.assertRaisesRegex(ValueError, 'plist'):
            artifact.validate_archive(root, self.expected, check_symbols=False)

    def test_archive_rejects_symlinks_and_mismatched_symbols(self):
        root = self.fixture()
        with patch.object(artifact, 'uuids', side_effect=[UUIDS, [('other', 'arm64')]]):
            with self.assertRaisesRegex(ValueError, 'UUID'):
                artifact.validate_archive(root, self.expected)
        (root / artifact.APP / 'link').symlink_to('/tmp')
        with self.assertRaisesRegex(ValueError, 'links'):
            artifact.regular_files(root)

    def test_realistic_ipa_directories_preserve_executable_permissions(self):
        bundle = self.root / 'app.ipa'
        with zipfile.ZipFile(bundle, 'w') as output:
            output.mkdir('Payload/')
            output.mkdir('Payload/Glimmer.app/')
            executable = zipfile.ZipInfo('Payload/Glimmer.app/Glimmer')
            executable.external_attr = (stat.S_IFREG | 0o755) << 16
            output.writestr(executable, b'inert')
        artifact.unpack(bundle, self.root / 'ipa', 'Payload')
        self.assertEqual((self.root / 'ipa/Payload/Glimmer.app/Glimmer').stat().st_mode & 0o777, 0o755)

    def test_unsafe_zip_entries_are_rejected_before_extraction(self):
        cases = [('Payload/../escape', stat.S_IFREG | 0o644),
                 ('/Payload/absolute', stat.S_IFREG | 0o644),
                 ('Payload/link', stat.S_IFLNK | 0o777),
                 ('Payload/fifo', stat.S_IFIFO | 0o600),
                 ('Payload/setuid', stat.S_IFREG | 0o4755),
                 ('Payload//alias', stat.S_IFREG | 0o644)]
        for index, (name, mode) in enumerate(cases):
            bundle = self.root / f'bad-{index}.zip'
            with zipfile.ZipFile(bundle, 'w') as output:
                entry = zipfile.ZipInfo(name)
                entry.external_attr = mode << 16
                output.writestr(entry, b'x')
            with self.subTest(name=name), self.assertRaises(ValueError):
                artifact.unpack(bundle, self.root / f'out-{index}', 'Payload')
            self.assertFalse((self.root / f'out-{index}').exists())

    def test_zip_size_budget_and_existing_destination_fail_closed(self):
        bundle = self.root / 'large.zip'
        with zipfile.ZipFile(bundle, 'w') as output:
            output.writestr('Payload/file', b'123456')
        with patch.object(artifact, 'MAX_BYTES', 5), self.assertRaises(ValueError):
            artifact.unpack(bundle, self.root / 'out', 'Payload')
        with self.assertRaises(ValueError):
            artifact.unpack(bundle, self.root, 'Payload')

    def test_artifact_metadata_binds_source_workflow_run_and_attempt(self):
        metadata = {'id': 44, 'name': 'ios-unsigned-123-2', 'expired': False,
                    'workflow_run': {'id': 123, 'head_sha': 'b' * 40}}
        cli.check_metadata(metadata, self.expected, '44')
        for key, value in [('id', 45), ('name', 'ios-unsigned-123-1'), ('expired', True),
                           ('workflow_run', {'id': 123, 'head_sha': 'a' * 40})]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                cli.check_metadata({**metadata, key: value}, self.expected, '44')

    def profile(self):
        team = 'ABCDEFGHIJ'
        return {'ExpirationDate': datetime.now() + timedelta(days=30), 'TeamIdentifier': [team],
                'UUID': UUIDS[0][0], 'DeveloperCertificates': [b'fixture'],
                'Entitlements': {'get-task-allow': False, 'application-identifier': f'{team}.{artifact.BUNDLE}',
                                 'com.apple.developer.team-identifier': team, 'beta-reports-active': True}}

    def test_distribution_profile_scope_and_expiry(self):
        valid = self.profile()
        signing.validate_profile(valid, 'ABCDEFGHIJ')
        invalid = []
        for key, value in [('ExpirationDate', datetime.now() - timedelta(days=1)), ('TeamIdentifier', ['OTHER']),
                           ('ProvisionedDevices', []), ('ProvisionsAllDevices', True)]:
            invalid.append({**valid, key: value})
        for key, value in [('get-task-allow', True), ('application-identifier', 'ABCDEFGHIJ.*'),
                           ('beta-reports-active', False)]:
            candidate = copy.deepcopy(valid)
            candidate['Entitlements'][key] = value
            invalid.append(candidate)
        for profile in invalid:
            with self.assertRaises(ValueError):
                signing.validate_profile(profile, 'ABCDEFGHIJ')

    def test_export_is_internal_only_and_preserves_build_number(self):
        options = signing.export_options('ABCDEFGHIJ', 'c' * 40, self.profile()['UUID'])
        self.assertEqual(options['method'], 'app-store-connect')
        self.assertEqual(options['destination'], 'export')
        self.assertEqual(options['signingStyle'], 'manual')
        self.assertTrue(options['testFlightInternalTestingOnly'])
        self.assertFalse(options['manageAppVersionAndBuildNumber'])
        self.assertEqual(set(options['provisioningProfiles']), {artifact.BUNDLE})

    def test_cleanup_attempts_keychain_deletion_after_search_list_timeout(self):
        root = self.root / 'ios-testflight-private'
        root.mkdir()
        (root / 'keychains.json').write_text(json.dumps(['/fixture/login.keychain-db']))
        (root / 'signing.keychain-db').touch()
        (root / 'distribution.p12').write_bytes(b'inert')
        outcomes = [subprocess.TimeoutExpired('security', 30), subprocess.CompletedProcess([], 0)]
        with patch.dict(os.environ, RUNNER_TEMP=str(self.root)):
            with patch.object(signing.subprocess, 'run', side_effect=outcomes) as call:
                with self.assertRaisesRegex(ValueError, 'cleanup'):
                    signing.cleanup()
                self.assertEqual(call.call_count, 2)
                self.assertEqual(call.call_args_list[1].args[0][1], 'delete-keychain')
        self.assertTrue((root / 'keychains.json').exists())
        self.assertFalse((root / 'distribution.p12').exists())

    def test_cleanup_preserves_failed_keychain_for_always_step_retry(self):
        root = self.root / 'ios-testflight-private'
        root.mkdir()
        (root / 'signing.keychain-db').touch()
        with patch.dict(os.environ, RUNNER_TEMP=str(self.root)):
            with patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
                with self.assertRaisesRegex(ValueError, 'cleanup'):
                    signing.cleanup()
            self.assertTrue((root / 'signing.keychain-db').exists())
            with patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
                signing.cleanup()
            self.assertFalse(root.exists())

    def test_delivery_receipt_drops_raw_messages_and_fails_unverified_output(self):
        success = signing.delivery_outcome(0, b'{"success-message":"Uploaded"}')
        self.assertEqual(success['status'], 'upload_and_processing_command_succeeded')
        for code, output in [(1, b'{}'), (0, b'not-json'), (0, b'[]'),
                             (0, b'{"errors":[{"code":123,"message":"sensitive detail"}]}')]:
            receipt = signing.delivery_outcome(code, output)
            self.assertEqual(receipt['status'], 'delivery_unconfirmed')
            self.assertNotIn('sensitive', json.dumps(receipt))

    def test_workflow_keeps_candidate_code_and_credentials_separate(self):
        workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/ios-testflight.yml').read_text()
        build = workflow.split('\n  archive:\n')[1].split('\n  distribute:\n')[0]
        signing_job = workflow.split('\n  distribute:\n')[1]
        self.assertNotIn('secrets.', build)
        self.assertNotIn('environment:', build)
        self.assertIn('environment: ios-testflight', signing_job)
        self.assertIn("github.ref == 'refs/heads/main'", signing_job)
        self.assertIn('ref: main', signing_job)
        self.assertNotIn('ref: ${{ inputs.expected_sha }}', signing_job)
        self.assertLess(signing_job.index('ios-testflight.py gate'), signing_job.index('IOS_DISTRIBUTION_P12_BASE64'))
        self.assertLess(signing_job.index('ios-testflight.py import'), signing_job.index('IOS_DISTRIBUTION_P12_BASE64'))
        self.assertLess(signing_job.index('Preserve signed bytes before upload'), signing_job.index('ASC_KEY_BASE64'))
        self.assertIn('if: always()\n        run: python3 scripts/ios-testflight.py cleanup', signing_job)
        self.assertNotIn('notarytool', workflow)


if __name__ == '__main__':
    unittest.main()
