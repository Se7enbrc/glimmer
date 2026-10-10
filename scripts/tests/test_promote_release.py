# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Promotion reuses verified public assets and never invokes signing or builds."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("promote_release", SCRIPTS / "promote-release.py")
PROMOTE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROMOTE)
SHA = "b" * 40
TAG = "2026.10.6-rc.1"
SHORT = "2026.10.6"
BUILD = "20261010"


class CandidatePromotionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="glimmer promotion fixture ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = patch.dict(os.environ, {"RUNNER_TEMP": str(self.root), "GITHUB_RUN_ID": "12",
                                          "GITHUB_RUN_ATTEMPT": "1", "EXPECTED_SHA": "a" * 40})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.calls = []
        self.sha = SHA
        self.source_changed = False
        self.attest_failure = False
        self.cas_response_failure = False
        self.assets = {f"Glimmer-{SHORT}.{suffix}": f"inert {suffix}".encode() for suffix in ("dmg", "zip")}
        self.data = {"id": 42, "tag_name": TAG, "draft": False, "prerelease": True,
                     "assets": [{"name": name, "size": len(data), "state": "uploaded",
                                 "digest": "sha256:" + hashlib.sha256(data).hexdigest()}
                                for name, data in self.assets.items()]}
        self.feed = (f'<rss xmlns:sparkle="{PROMOTE.SPARKLE}"><channel><item><title>RC</title>'
                     f'<sparkle:version>{BUILD}</sparkle:version><sparkle:shortVersionString>{SHORT}</sparkle:shortVersionString>'
                     '<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion><sparkle:channel>rc</sparkle:channel>'
                     f'<enclosure url="https://github.com/{PROMOTE.REPO}/releases/download/{TAG}/Glimmer-{SHORT}.zip" '
                     f'sparkle:edSignature="inert-signature" length="{len(self.assets[f"Glimmer-{SHORT}.zip"])}"/>'
                     '</item></channel></rss>')
        self.mock = patch.object(PROMOTE, "command", side_effect=self.command)
        self.mock.start()
        self.addCleanup(self.mock.stop)

    def command(self, args, message):
        self.calls.append(args)
        if args[:2] == ["git", "fetch"]:
            return ""
        if args[:2] == ["git", "rev-parse"]:
            return os.environ["EXPECTED_SHA"] + "\n"
        if args[:2] == ["git", "diff"]:
            self.assertEqual(args[-2:], [".", ":(exclude)appcast.xml"])
            if self.source_changed:
                raise ValueError(message)
            return ""
        if args[:2] == ["git", "show"]:
            if args[2].endswith(":appcast.xml"):
                return self.feed
            return f"MARKETING_VERSION = {SHORT}\nCURRENT_PROJECT_VERSION = {BUILD}\n"
        if args[:2] == ["gh", "api"]:
            return self.sha if "/commits/" in args[2] else json.dumps(self.data)
        if args[:3] == ["gh", "release", "download"]:
            for name, data in self.assets.items():
                (PROMOTE.directory() / name).write_bytes(data)
            return ""
        if args[:3] == ["gh", "attestation", "verify"]:
            self.assertEqual(args[-2:], ["--source-digest", SHA])
            self.assertIn(PROMOTE.WORKFLOW, args)
            self.assertIn("refs/heads/release-candidate", args)
            if self.attest_failure:
                raise ValueError(message)
            return ""
        if args[:3] == ["gh", "release", "edit"]:
            self.assertIn("--prerelease=false", args)
            self.assertIn("--latest", args)
            self.data["prerelease"] = False
            return ""
        if args[1] == "scripts/update-appcast.py":
            result = subprocess.run([sys.executable, str(SCRIPTS / "update-appcast.py"), *args[2:]],
                                    capture_output=True, text=True)
            if result.returncode:
                raise ValueError(message)
            return ""
        if args[1] == "scripts/github_signed_commit.py":
            self.feed = Path(args[5]).read_text()
            if self.cas_response_failure:
                raise ValueError(message)
            return "c" * 40
        raise AssertionError(args)

    def test_promotes_same_tag_and_exact_verified_bytes_without_builds_or_signing(self):
        PROMOTE.prepare(TAG, SHA)
        before = {name: (PROMOTE.directory() / name).read_bytes() for name in self.assets}
        PROMOTE.publish(TAG, SHA)
        self.assertEqual(before, {name: (PROMOTE.directory() / name).read_bytes() for name in self.assets})
        self.assertFalse(self.data["prerelease"])
        self.assertNotIn("<sparkle:channel>", self.feed)
        self.assertIn(f"/releases/download/{TAG}/", self.feed)
        self.assertFalse(any(args[0] in {"make", "codesign", "ditto", "zip", "xcodebuild"} for args in self.calls))

    def test_wrong_source_or_changed_main_stops_before_download_or_publication(self):
        for changed in ("tag", "tree"):
            self.calls.clear()
            self.sha = "c" * 40 if changed == "tag" else SHA
            self.source_changed = changed == "tree"
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                PROMOTE.prepare(TAG, SHA)
            self.assertFalse(any(args[:2] == ["gh", "release"] for args in self.calls))

    def test_missing_or_failed_attestation_cannot_authorize_promotion(self):
        self.attest_failure = True
        with self.assertRaisesRegex(ValueError, "provenance"):
            PROMOTE.prepare(TAG, SHA)
        self.assertFalse((PROMOTE.directory() / "verified.json").exists())
        with self.assertRaises(OSError):
            PROMOTE.publish(TAG, SHA)
        self.assertTrue(self.data["prerelease"])

    def test_changed_missing_or_remote_replaced_bytes_are_rejected(self):
        PROMOTE.prepare(TAG, SHA)
        path = PROMOTE.directory() / f"Glimmer-{SHORT}.zip"
        original = path.read_bytes()
        for data in (b"replaced", None):
            if data is None:
                path.unlink()
            else:
                path.write_bytes(data)
            with self.subTest(data=data), self.assertRaises((ValueError, OSError)):
                PROMOTE.publish(TAG, SHA)
            self.assertTrue(self.data["prerelease"])
            path.write_bytes(original)
        self.data["assets"][0]["digest"] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(ValueError, "published candidate asset changed"):
            PROMOTE.publish(TAG, SHA)

    def test_lost_cas_response_can_retry_already_stable_feed_without_new_commit(self):
        PROMOTE.prepare(TAG, SHA)
        self.cas_response_failure = True
        with self.assertRaises(ValueError):
            PROMOTE.publish(TAG, SHA)
        self.assertFalse(self.data["prerelease"])
        self.cas_response_failure = False
        os.environ["EXPECTED_SHA"] = "c" * 40
        self.calls.clear()
        PROMOTE.publish(TAG, SHA)
        self.assertFalse(any(args[1] == "scripts/github_signed_commit.py" for args in self.calls))

    def test_incomplete_digest_proof_and_changed_enclosure_are_rejected(self):
        PROMOTE.prepare(TAG, SHA)
        path = PROMOTE.directory() / "verified.json"
        proof = json.loads(path.read_text())
        proof["hashes"].pop(f"Glimmer-{SHORT}.dmg")
        path.write_text(json.dumps(proof))
        with self.assertRaisesRegex(ValueError, "incomplete"):
            PROMOTE.validate(TAG, SHA)
        self.feed = self.feed.replace("inert-signature", "different-signature")
        with self.assertRaisesRegex(ValueError, "changed after provenance"):
            PROMOTE.validate(TAG, SHA)


if __name__ == "__main__":
    unittest.main()
