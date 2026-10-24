# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Export policy and upload checks use inert bytes and mocked Apple tools."""

import copy
import importlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
signing = importlib.import_module('ios-testflight-sign')
artifact = importlib.import_module('ios-testflight-artifact')

TEAM = 'ABCDEFGHIJ'
PROFILE = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA'
OPTIONS = {'method': 'app-store-connect', 'destination': 'export', 'signingStyle': 'manual',
           'teamID': TEAM, 'signingCertificate': 'C' * 40,
           'provisioningProfiles': {artifact.BUNDLE: PROFILE},
           'testFlightInternalTestingOnly': False, 'manageAppVersionAndBuildNumber': False,
           'stripSwiftSymbols': True, 'uploadSymbols': True}


class ExportPolicyTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.expected = {'EXPECTED_SHA': 'a' * 40, 'IOS_VERSION': '0.1.1', 'IOS_BUILD_NUMBER': '3',
                         'GITHUB_REPOSITORY': artifact.REPOSITORY,
                         'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '2'}
        env = {'RUNNER_TEMP': str(self.root), 'IOS_TEAM_ID': TEAM,
               'TRUSTED_TOOLING_SHA': 'b' * 40, 'GITHUB_RUN_ID': '456', 'GITHUB_RUN_ATTEMPT': '1',
               'ASC_KEY_ID': 'K' * 10, 'ASC_ISSUER_ID': PROFILE}
        self.enterContext(patch.dict(os.environ, env, clear=True))
        self.enterContext(patch.object(artifact, 'require_dispatch'))
        self.tool = self.enterContext(patch.object(signing.subprocess, 'run'))
        self.secret = self.enterContext(patch.object(signing, 'secret_file'))
        self.cleanup = self.enterContext(patch.object(signing, 'cleanup'))
        (self.root / 'Glimmer.ipa').write_bytes(b'inert IPA fixture')
        self.receipt = {'schema': 2, 'identity': self.expected, 'external_testing_eligible': True,
                        'team': TEAM, 'trusted_tooling_sha': 'b' * 40,
                        'signing_run_id': '456', 'signing_run_attempt': '1',
                        'ipa_sha256': artifact.digest(self.root / 'Glimmer.ipa'),
                        'export_options': copy.deepcopy(OPTIONS), 'app_uuids': [[PROFILE, 'arm64']]}

    def upload(self, receipt):
        (self.root / 'receipt.json').write_text(json.dumps(receipt))
        signing.upload(self.root, self.expected)

    def test_export_options_are_exactly_the_reviewed_set(self):
        self.assertEqual(signing.export_options(TEAM, 'C' * 40, PROFILE), OPTIONS)

    def test_upload_accepts_external_eligible_receipt(self):
        self.tool.side_effect = [
            subprocess.CompletedProcess([], 0, b'--upload-package --api-key --api-issuer --wait', b''),
            subprocess.CompletedProcess([], 0, b'{"success-message":"Uploaded"}', b'')]
        self.upload(self.receipt)
        self.assertIn('--upload-package', self.tool.call_args.args[0])
        self.secret.assert_called_once()
        self.cleanup.assert_called_once()
        result = json.loads((self.root / 'upload.json').read_text())
        self.assertEqual(result['status'], 'upload_and_processing_command_succeeded')

    def rejected(self, receipt):
        self.tool.reset_mock()
        self.secret.reset_mock()
        with self.assertRaises(ValueError):
            self.upload(receipt)
        self.tool.assert_not_called()
        self.secret.assert_not_called()
        self.assertFalse((self.root / 'ios-testflight-private').exists())

    def test_upload_rejects_missing_extra_changed_and_mistyped_options_before_credentials(self):
        variants = [None, [], {**OPTIONS, 'compileBitcode': False}]
        for key, value in OPTIONS.items():
            variants.append({name: item for name, item in OPTIONS.items() if name != key})
            variants.append({**OPTIONS, key: not value if isinstance(value, bool) else 'unexpected'})
            variants.append({**OPTIONS, key: int(value) if isinstance(value, bool) else None})
        variants.extend([{**OPTIONS, 'provisioningProfiles': profiles} for profiles in (
            {}, {artifact.BUNDLE: None}, {artifact.BUNDLE: 'invalid'},
            {artifact.BUNDLE: PROFILE, 'other.app': PROFILE})])
        for options in variants:
            with self.subTest(options=options):
                self.rejected({**self.receipt, 'export_options': options})

    def test_upload_rejects_legacy_policy_and_identity_mismatches(self):
        variants = [{key: value for key, value in self.receipt.items()
                     if key != 'external_testing_eligible'},
                    {**self.receipt, 'internal_only': True}]
        for key, values in {'schema': [1, None], 'external_testing_eligible': [False, 1, 'true'],
                            'identity': [{**self.expected, 'EXPECTED_SHA': 'd' * 40}],
                            'ipa_sha256': ['0' * 64], 'team': ['OTHERTEAM1', None]}.items():
            variants.extend({**self.receipt, key: value} for value in values)
        for receipt in variants:
            with self.subTest(receipt=receipt):
                self.rejected(receipt)

    def test_export_records_the_options_passed_to_xcode_without_internal_only_field(self):
        output = self.root / 'export'
        private = self.root / 'ios-testflight-private'
        private.mkdir()
        app = private / 'inspected/Payload/Glimmer.app'
        app.mkdir(parents=True)

        def export_archive(arguments, **_kwargs):
            self.assertEqual(arguments[0:2], ['xcodebuild', '-exportArchive'])
            options = plistlib.loads((private / 'ExportOptions.plist').read_bytes())
            self.assertEqual(options, OPTIONS)
            output.mkdir()
            (output / 'Glimmer.ipa').write_bytes(b'inert exported IPA')
            return subprocess.CompletedProcess(arguments, 0)

        self.tool.side_effect = export_archive
        with (patch.object(signing, 'credentials', return_value=copy.deepcopy(OPTIONS)),
              patch.object(artifact, 'validate_archive'), patch.object(artifact, 'unpack'),
              patch.object(signing, 'verify_signed_app'),
              patch.object(artifact, 'uuids', return_value=[(PROFILE, 'arm64')])):
            signing.export(self.root / 'Glimmer.xcarchive', output, self.expected)
        receipt = json.loads((output / 'receipt.json').read_text())
        self.assertEqual(receipt, {**self.receipt, 'ipa_sha256': artifact.digest(output / 'Glimmer.ipa')})
        self.cleanup.assert_called_once()

    def test_export_rejects_unreviewed_options_before_xcode(self):
        with (patch.object(signing, 'credentials', return_value={**OPTIONS, 'destination': 'upload'}),
              patch.object(artifact, 'validate_archive'), self.assertRaises(ValueError)):
            signing.export(self.root / 'Glimmer.xcarchive', self.root / 'export', self.expected)
        self.tool.assert_not_called()
        self.cleanup.assert_called_once()


if __name__ == '__main__':
    unittest.main()
