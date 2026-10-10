# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Update signatures verify against the app's public key, not the signing key's own."""

import base64
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "verify-update-signature.swift"

# RFC 8032 section 7.1, test 1: the empty message.
PUBLIC = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
SIGNATURE = bytes.fromhex(
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")


def verify(public, signature, archive):
    return subprocess.run(["swift", str(SCRIPT), base64.b64encode(public).decode(),
                           base64.b64encode(signature).decode(), str(archive)],
                          capture_output=True, check=False).returncode


class UpdateSignatureTests(unittest.TestCase):
    def test_signature_must_match_the_app_key(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "Glimmer.zip"
            archive.write_bytes(b"")
            self.assertEqual(verify(PUBLIC, SIGNATURE, archive), 0)
            other_key = bytes([PUBLIC[0] ^ 1]) + PUBLIC[1:]
            self.assertNotEqual(verify(other_key, SIGNATURE, archive), 0)
            archive.write_bytes(b"x")
            self.assertNotEqual(verify(PUBLIC, SIGNATURE, archive), 0)


if __name__ == "__main__":
    unittest.main()
