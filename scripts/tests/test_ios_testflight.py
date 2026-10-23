# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Inert TestFlight trust, signing-policy and artifact regression fixtures."""

import copy
from datetime import datetime, timedelta
import hashlib
import importlib
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import warnings
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

    def test_builder_runs_only_its_exact_nondefault_branch_commit(self):
        env = {**ENV, 'GITHUB_SHA': 'a' * 40, 'GITHUB_REF': 'refs/heads/candidate', 'DEFAULT_BRANCH': 'main',
               'GITHUB_WORKFLOW_REF': 'Se7enbrc/glimmer/.github/workflows/ios-testflight-build.yml@refs/heads/candidate'}
        artifact.require_builder(env)
        for key, value in [('GITHUB_SHA', 'c' * 40), ('GITHUB_REF', 'refs/heads/main'),
                           ('DEFAULT_BRANCH', 'candidate'), ('DEFAULT_BRANCH', ''),
                           ('GITHUB_EVENT_NAME', 'pull_request_target')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                artifact.require_builder({**env, key: value})

    def test_producer_identity_is_separate_from_the_protected_workflow_run(self):
        env = {**ENV, 'ARCHIVE_RUN_ID': '800', 'ARCHIVE_ATTEMPT': '4'}
        identity = artifact.identity(env)
        self.assertEqual(identity['GITHUB_RUN_ID'], '800')
        self.assertEqual(identity['GITHUB_RUN_ATTEMPT'], '4')
        self.assertNotIn('TRUSTED_TOOLING_SHA', identity)

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

    def unsafe_zip(self, path, entries):
        with zipfile.ZipFile(path, 'w') as output, warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)  # zipfile warns on the duplicate fixture
            for name, mode in entries:
                entry = zipfile.ZipInfo(name)
                entry.external_attr = mode << 16
                output.writestr(entry, b'x')

    def test_unsafe_zip_entries_are_rejected_before_extraction(self):
        cases = [('traversal', [('Payload/../escape', stat.S_IFREG | 0o644)]),
                 ('absolute', [('/Payload/absolute', stat.S_IFREG | 0o644)]),
                 ('link-or-special', [('Payload/link', stat.S_IFLNK | 0o777)]),
                 ('link-or-special', [('Payload/fifo', stat.S_IFIFO | 0o600)]),
                 ('privileged-bits', [('Payload/setuid', stat.S_IFREG | 0o4755)]),
                 ('noncanonical', [('Payload//alias', stat.S_IFREG | 0o644)]),
                 ('unexpected-root', [('Symbols/A.symbols', stat.S_IFREG | 0o644)]),
                 ('directory-mode-on-file', [('Payload/dir', stat.S_IFDIR | 0o755)]),
                 ('duplicate', [('Payload/twice', stat.S_IFREG | 0o644)] * 2),
                 ('backslash', [('Payload\\windows', stat.S_IFREG | 0o644)]),
                 ('too-long', [('Payload/' + 'a/' * 40 + 'deep', stat.S_IFREG | 0o644)])]
        for index, (reason, entries) in enumerate(cases):
            bundle = self.root / f'bad-{index}.zip'
            self.unsafe_zip(bundle, entries)
            with self.subTest(reason=reason), self.assertRaises(artifact.UnsafeEntries) as caught:
                artifact.unpack(bundle, self.root / f'out-{index}', ('Payload', 'SwiftSupport'))
            self.assertEqual(caught.exception.report['violations'][0]['reason'], reason)
            self.assertFalse((self.root / f'out-{index}').exists())

    def test_rejection_reports_every_entry_bounded_and_escaped(self):
        bundle = self.root / 'many.ipa'
        hostile = 'Other/\x1b[31m‮' + 'x' * 400
        self.unsafe_zip(bundle, [('Payload/Glimmer.app/Glimmer', stat.S_IFREG | 0o755), (hostile, stat.S_IFREG | 0o644)]
                        + [(f'Symbols/{n}.symbols', stat.S_IFREG | 0o644) for n in range(30)])
        with self.assertRaises(artifact.UnsafeEntries) as caught:
            artifact.unpack(bundle, self.root / 'out', ('Payload', 'SwiftSupport'))
        report = caught.exception.report
        self.assertEqual(report['violation_count'], 31)
        self.assertEqual(len(report['violations']), artifact.MAX_REPORTED)
        self.assertEqual(report['roots'], {'Symbols': 30, 'Payload': 1, 'Other': 1})
        self.assertEqual(report['violations'][0], {'reason': 'unexpected-root', 'type': 'file', 'mode': '0644',
                                                   'path': ascii(hostile)[1:-1][:artifact.MAX_REPORTED_PATH]})
        self.assertTrue(all(value.isascii() and value.isprintable() and len(value) <= artifact.MAX_REPORTED_PATH
                            for item in report['violations'] for value in item.values()))
        stderr = io.StringIO()
        with patch.object(cli.signing, 'export', side_effect=caught.exception), patch.object(cli, 'toolchain'), \
                patch.object(sys, 'argv', ['ios-testflight.py', 'export']), patch.dict(os.environ, ENV), \
                patch.object(sys, 'stderr', stderr), self.assertRaises(SystemExit):
            cli.main()
        lines = stderr.getvalue().splitlines()
        self.assertEqual(json.loads(lines[0].removeprefix('ERR: entry report ')), report)
        self.assertTrue(lines[1].startswith('ERR: unsafe or duplicate artifact entry (31 total): unexpected-root Other/'))
        self.assertLess(len(stderr.getvalue()), 16 * 1024)

    def test_diagnostics_keep_the_accepted_ipa_shape(self):
        bundle = self.root / 'accepted.ipa'
        self.unsafe_zip(bundle, [('Payload/Glimmer.app/Glimmer', stat.S_IFREG | 0o755),
                                 ('Payload/Glimmer.app/unset-mode', 0),
                                 ('SwiftSupport/iphoneos/libswiftCore.dylib', stat.S_IFREG | 0o644)])
        artifact.unpack(bundle, self.root / 'ipa', ('Payload', 'SwiftSupport'))
        self.assertEqual((self.root / 'ipa/Payload/Glimmer.app/unset-mode').stat().st_mode & 0o777, 0o600)

    def test_exported_symbols_must_be_exactly_the_app_uuids(self):
        uuid = '54A97B0B-4991-30CD-9AE6-6DE03CEC217A'
        other = '00000000-0000-0000-0000-000000000000'
        app_uuids = [(uuid, 'arm64')]
        # The shape Xcode's App Store export produced in delivery run 39840393056.
        bundle = self.root / 'export.ipa'
        self.unsafe_zip(bundle, [('Payload/Glimmer.app/Glimmer', stat.S_IFREG | 0o755),
                                 ('Symbols/', stat.S_IFDIR | 0o755),
                                 (f'Symbols/{uuid}.symbols', stat.S_IFREG | 0o644)])
        inspected = self.root / 'ipa'
        artifact.unpack(bundle, inspected, ('Payload', 'SwiftSupport', 'Symbols'))
        signing.verify_exported_symbols(inspected, app_uuids)
        signing.verify_exported_symbols(self.root / 'no-symbols', app_uuids)
        for app in ([(other, 'arm64')], [(uuid, 'arm64'), (other, 'arm64')]):
            with self.subTest(app=app), self.assertRaises(ValueError):
                signing.verify_exported_symbols(inspected, app)
        symbols = inspected / 'Symbols'
        for name, make in [('extra.symbols', lambda p: p.write_bytes(b'x')), ('nested', Path.mkdir),
                           (f'{other}.symbols', lambda p: p.symlink_to(symbols / f'{uuid}.symbols'))]:
            make(symbols / name)
            with self.subTest(name=name), self.assertRaises(ValueError):
                signing.verify_exported_symbols(inspected, app_uuids)
            (symbols / name).rmdir() if name == 'nested' else (symbols / name).unlink()
        (symbols / f'{uuid}.symbols').unlink()
        with self.assertRaises(ValueError):
            signing.verify_exported_symbols(inspected, app_uuids)

    def test_zip_size_budget_and_existing_destination_fail_closed(self):
        bundle = self.root / 'large.zip'
        with zipfile.ZipFile(bundle, 'w') as output:
            output.writestr('Payload/file', b'123456')
        with patch.object(artifact, 'MAX_BYTES', 5), self.assertRaises(ValueError):
            artifact.unpack(bundle, self.root / 'out', 'Payload')
        with self.assertRaises(ValueError):
            artifact.unpack(bundle, self.root, 'Payload')

    def test_artifact_metadata_binds_source_workflow_run_and_attempt(self):
        metadata = {'id': 44, 'name': 'ios-unsigned-123-2', 'expired': False, 'digest': 'sha256:' + 'd' * 64,
                    'workflow_run': {'id': 123, 'head_sha': 'a' * 40}}
        cli.check_metadata(metadata, self.expected, '44')
        for key, value in [('id', 45), ('name', 'ios-unsigned-123-1'), ('expired', True),
                           ('workflow_run', {'id': 123, 'head_sha': 'b' * 40}), ('digest', '')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                cli.check_metadata({**metadata, key: value}, self.expected, '44')

    def download_fixture(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as output:
            output.writestr('archive.zip', b'inert archive bytes')
            output.writestr('manifest.json', b'{"fixture":true}\n')
        data = stream.getvalue()
        digest = 'sha256:' + hashlib.sha256(data).hexdigest()
        metadata = {'id': 44, 'name': 'ios-unsigned-123-2', 'expired': False, 'digest': digest,
                    'workflow_run': {'id': 123, 'head_sha': 'a' * 40}}
        return data, digest, metadata

    def fake_download(self, data):
        def complete(*_arguments, **options):
            options['stdout'].write(data)
            options['stdout'].flush()
            process = Mock(returncode=0)
            process.poll.return_value = 0
            return process
        return complete

    def test_download_rejects_metadata_digest_change_before_fetching_bytes(self):
        _, digest, metadata = self.download_fixture()
        metadata['digest'] = 'sha256:' + '0' * 64
        result = subprocess.CompletedProcess([], 0, stdout=json.dumps(metadata))
        with patch.dict(os.environ, ARCHIVE_DIGEST=digest):
            with patch.object(cli.subprocess, 'run', return_value=result):
                with patch.object(cli.subprocess, 'Popen') as fetch:
                    with self.assertRaisesRegex(ValueError, 'changed after'):
                        cli.download('44', self.root / 'payload', self.expected)
                    fetch.assert_not_called()
        self.assertFalse((self.root / 'payload').exists())

    def test_download_rejects_zip_byte_mismatch_before_parsing_or_extraction(self):
        data, digest, metadata = self.download_fixture()
        result = subprocess.CompletedProcess([], 0, stdout=json.dumps(metadata))
        with patch.dict(os.environ, ARCHIVE_DIGEST=digest):
            with patch.object(cli.subprocess, 'run', return_value=result):
                with patch.object(cli.subprocess, 'Popen', side_effect=self.fake_download(data + b'tampered')):
                    with patch.object(cli.zipfile, 'ZipFile') as parse:
                        with self.assertRaisesRegex(ValueError, 'differs from'):
                            cli.download('44', self.root / 'payload', self.expected)
                        parse.assert_not_called()
        self.assertFalse((self.root / 'payload').exists())

    def test_download_verified_outer_zip_roundtrips_exact_payload_bytes(self):
        data, digest, metadata = self.download_fixture()
        result = subprocess.CompletedProcess([], 0, stdout=json.dumps(metadata))
        with patch.dict(os.environ, ARCHIVE_DIGEST=digest):
            with patch.object(cli.subprocess, 'run', return_value=result):
                with patch.object(cli.subprocess, 'Popen', side_effect=self.fake_download(data)):
                    cli.download('44', self.root / 'payload', self.expected)
        self.assertEqual({p.name for p in (self.root / 'payload').iterdir()}, {'archive.zip', 'manifest.json'})
        self.assertEqual((self.root / 'payload/archive.zip').read_bytes(), b'inert archive bytes')
        self.assertEqual((self.root / 'payload/manifest.json').read_bytes(), b'{"fixture":true}\n')

    def test_build_run_requires_workflow_source_repository_success_and_branch(self):
        run = {'id': 123, 'head_sha': 'a' * 40, 'head_repository': {'full_name': 'Se7enbrc/glimmer'},
               'event': 'workflow_dispatch', 'path': cli.BUILD_WORKFLOW, 'workflow_id': 17,
               'status': 'completed', 'conclusion': 'success', 'head_branch': 'candidate', 'run_attempt': 2}
        cli.check_build_run(run, self.expected, 17, 'main')
        for key, value in [('id', 124), ('head_sha', 'b' * 40), ('head_repository', {'full_name': 'fork/glimmer'}),
                           ('event', 'pull_request_target'), ('path', '.github/workflows/other.yml'),
                           ('workflow_id', 18), ('status', 'in_progress'), ('conclusion', 'failure'),
                           ('head_branch', 'main'), ('run_attempt', 0)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                cli.check_build_run({**run, key: value}, self.expected, 17, 'main')
        with self.assertRaises(ValueError):
            cli.check_build_run(run, self.expected, 17, 'candidate')

    def test_resolve_selects_exact_producing_attempt_and_emits_digest(self):
        checks = importlib.import_module('release-checks')
        workflow = {'id': 17, 'path': cli.BUILD_WORKFLOW, 'state': 'active'}
        run = {'id': 123, 'head_sha': 'a' * 40, 'head_repository': {'full_name': 'Se7enbrc/glimmer'},
               'event': 'workflow_dispatch', 'path': cli.BUILD_WORKFLOW, 'workflow_id': 17,
               'status': 'completed', 'conclusion': 'success', 'head_branch': 'candidate', 'run_attempt': 4}
        metadata = {'id': 44, 'name': 'ios-unsigned-123-4', 'expired': False, 'digest': 'sha256:' + 'd' * 64,
                    'workflow_run': {'id': 123, 'head_sha': 'a' * 40}}
        with patch.dict(os.environ, {**ENV, 'DEFAULT_BRANCH': 'main'}, clear=True):
            with patch.object(checks, 'object_api', side_effect=[workflow, run]):
                with patch.object(checks, 'api', return_value=[{'artifacts': [metadata]}]):
                    with patch.object(cli, 'write_outputs') as write:
                        cli.resolve(self.expected)
        write.assert_called_once_with(artifact=44, attempt='4', digest='sha256:' + 'd' * 64)

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

    def test_delivery_receipt_keeps_only_capped_apple_reasons_and_fails_unverified_output(self):
        success = signing.delivery_outcome(0, b'{"success-message":"Uploaded"}')
        self.assertEqual(success['status'], 'upload_and_processing_command_succeeded')
        for code, output in [(1, b'{}'), (0, b'not-json'), (0, b'[]'),
                             (0, b'{"errors":[{"code":123,"message":"m","other":"sensitive detail"}]}')]:
            receipt = signing.delivery_outcome(code, output)
            self.assertEqual(receipt['status'], 'delivery_unconfirmed')
            self.assertNotIn('sensitive', json.dumps(receipt))
        error = {'code': 90039, 'message': 'x' * 900, 'userInfo': {
            'NSLocalizedFailureReason': 'reason', 'NSUnderlyingError': 'sensitive detail'}}
        receipt = signing.delivery_outcome(1, json.dumps({'product-errors': [error]}).encode())
        self.assertEqual(receipt['error_codes'], ['90039'])
        self.assertEqual(len(receipt['error_messages'][0]), 500)
        self.assertNotIn('sensitive', json.dumps(receipt))
        receipt = signing.delivery_outcome(1, b'{"errors":[{"code":1,"message":"m","userInfo":{"NSLocalizedFailureReason":"r"}}]}')
        self.assertEqual(receipt['error_messages'], ['m | r'])

    def test_workflow_keeps_candidate_code_and_credentials_separate(self):
        workflows = Path(__file__).resolve().parents[2] / '.github/workflows'
        workflow = (workflows / 'ios-testflight.yml').read_text()
        build = (workflows / 'ios-testflight-build.yml').read_text()
        signing_job = workflow.split('\n  distribute:\n')[1]
        self.assertNotIn('secrets.', build)
        self.assertNotIn('environment:', build)
        self.assertNotIn('id-token:', build)
        self.assertNotIn('actions/cache', build)
        self.assertIn('ref: ${{ github.sha }}', build)
        self.assertNotIn('ref: ${{ inputs.expected_sha }}', build)
        self.assertIn("github.ref != 'refs/heads/main'", build)
        self.assertIn('github.event.repository.default_branch', build)
        self.assertNotIn('ios-testflight.py archive', workflow)
        self.assertNotIn('ref: ${{ inputs.expected_sha }}', workflow)
        self.assertIn('archive_run_id:', workflow)
        self.assertIn('ios-testflight.py resolve', workflow)
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
