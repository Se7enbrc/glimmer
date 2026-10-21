# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Certificate membership must use complete certificate bytes, not legacy selectors."""

import importlib
from pathlib import Path
import ssl
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
signing = importlib.import_module('ios-testflight-sign')


class SigningIdentityTests(unittest.TestCase):
    fingerprint = 'A' * 40
    identity = f'1) {fingerprint} "Apple Distribution: Example (ABCDEFGHIJ)"\n1 valid identities found'
    certificate = b'inert certificate bytes for membership tests'

    def test_exact_certificate_membership_returns_system_selector(self):
        pem = ssl.DER_cert_to_PEM_cert(self.certificate)
        profile = {'DeveloperCertificates': [b'another certificate', self.certificate]}
        self.assertEqual(signing.signing_identity(self.identity, pem, profile), self.fingerprint)

    def test_same_selector_cannot_authorize_different_certificate_bytes(self):
        pem = ssl.DER_cert_to_PEM_cert(self.certificate + b'tampered')
        with self.assertRaisesRegex(ValueError, 'exactly match'):
            signing.signing_identity(self.identity, pem, {'DeveloperCertificates': [self.certificate]})

    def test_missing_or_ambiguous_identities_and_certificates_fail(self):
        pem = ssl.DER_cert_to_PEM_cert(self.certificate)
        profile = {'DeveloperCertificates': [self.certificate]}
        for identities, certificates in [('', pem), (self.identity * 2, pem),
                                         (self.identity, ''), (self.identity, pem * 2)]:
            with self.subTest(identities=identities, certificates=certificates):
                with self.assertRaisesRegex(ValueError, 'exactly one'):
                    signing.signing_identity(identities, certificates, profile)

    def test_non_distribution_identity_is_not_a_signing_candidate(self):
        identity = self.identity.replace('Apple Distribution:', 'Apple Development:')
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            signing.signing_identity(identity, ssl.DER_cert_to_PEM_cert(self.certificate),
                                     {'DeveloperCertificates': [self.certificate]})


if __name__ == '__main__':
    unittest.main()
