# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Promotion reuses verified public assets and never invokes signing or builds."""

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from fixture_git import FixtureTestCase
import test_candidate_ref_checks as candidate_fixture
from unittest.mock import Mock, patch

SCRIPTS = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("promote_release", SCRIPTS / "promote-release.py")
PROMOTE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROMOTE)
SPEC = importlib.util.spec_from_file_location("release_candidate", SCRIPTS / "release-candidate.py")
CANDIDATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CANDIDATE)
SHA = "b" * 40
TAG = "2026.10.6-rc.1"
SHORT = "2026.10.6"
BUILD = "20261010"


class CandidatePromotionTests(FixtureTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="glimmer promotion fixture ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = patch.dict(os.environ, {"RUNNER_TEMP": str(self.root), "GITHUB_RUN_ID": "12",
                                          "GITHUB_RUN_ATTEMPT": "1", "EXPECTED_SHA": "a" * 40})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.calls = []
        self.remote_tags = {}
        self.local_tags = {}
        self.sha = SHA
        self.source_changed = False
        self.attest_failure = False
        self.cas_response_failure = False
        self.feed_head = "e" * 40
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

    def command(self, args, message, *, read_only=False):
        self.calls.append(args)
        if args[:2] in (["git", "ls-remote"], ["git", "tag"], ["git", "push"]) or (
                args[:2] == ["git", "rev-parse"] and args[2].startswith("refs/tags/")):
            return self.tag_command(args, message)
        if args[:2] == ["git", "fetch"]:
            self.assertIn("+refs/heads/appcast:refs/remotes/origin/appcast", args)
            return ""
        if args == ["git", "rev-parse", "refs/remotes/origin/appcast"]:
            return self.feed_head + "\n"
        if args[:2] == ["git", "rev-parse"]:
            return os.environ["EXPECTED_SHA"] + "\n"
        if args[:2] == ["git", "diff"]:
            self.assertEqual(args[5:], ["--", *PROMOTE.SHIPPED])
            if self.source_changed:
                raise ValueError(message)
            return ""
        if args[:2] == ["git", "show"]:
            if args[2].endswith(":appcast.xml"):
                self.assertEqual(args[2], f"{self.feed_head}:appcast.xml")
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
        if args[1] == "scripts/release-checks.py":
            self.assertEqual(args[2:], [SHA, "--candidate", "--delivery"])
            return ""
        if args[1] == "scripts/update-appcast.py":
            result = subprocess.run([sys.executable, str(SCRIPTS / "update-appcast.py"), *args[2:]],
                                    capture_output=True, text=True)
            if result.returncode:
                raise ValueError(message)
            return ""
        if args[1] == "scripts/github_signed_commit.py":
            self.assertEqual(args[2:6], [PROMOTE.REPO, "appcast", self.feed_head, "appcast.xml"])
            self.feed = Path(args[6]).read_text()
            if self.cas_response_failure:
                raise ValueError(message)
            self.feed_head = "f" * 40
            return self.feed_head
        raise AssertionError(args)

    def tag_command(self, args, message):
        ref = f"refs/tags/{SHORT}"
        if args[:2] == ["git", "ls-remote"]:
            self.assertEqual(args[2:], ["origin", ref, f"{ref}^{{}}"])
            return "".join(f"{target}\t{name}\n" for name, target in self.remote_tags.items())
        if args[:3] == ["git", "tag", "--list"]:
            return SHORT if SHORT in self.local_tags else ""
        if args[:2] == ["git", "rev-parse"]:
            self.assertEqual(args[2], f"{ref}^{{commit}}")
            return self.local_tags[SHORT]
        if args[:3] == ["git", "tag", "-a"]:
            self.assertEqual(args, ["git", "tag", "-a", SHORT, SHA, "-m", SHORT])
            self.assertNotIn(SHORT, self.local_tags)
            self.local_tags[SHORT] = SHA
            return ""
        if args[:2] == ["git", "push"]:
            self.assertEqual(args, ["git", "push", "origin", ref])
            self.remote_tags.update({ref: "d" * 40, f"{ref}^{{}}": self.local_tags[SHORT]})
            return ""
        raise AssertionError(args)

    def test_current_candidate_verdict_is_required_for_prepare_tag_publish_and_tap_validation(self):
        PROMOTE.prepare(TAG, SHA)
        for reason in ('unreserved', 'ref moved', 'ref missing', 'direct scans absent', 'candidate alert open'):
            fixture = candidate_fixture.CandidateRefChecksTests()
            with patch.object(candidate_fixture, 'SHA', SHA):
                fixture.setUp()
                for run in fixture.runs:
                    run['head_sha'] = SHA
                for job in fixture.jobs.values():
                    job['head_sha'] = SHA
                original = fixture.objects
                def objects(path):
                    if reason == 'ref missing' and path == 'git/ref/heads/release-candidate':
                        raise ValueError('missing candidate ref')
                    result = original(path)
                    if reason == 'unreserved' and path.startswith('git/commits/'):
                        result['message'] = json.dumps({'schema': 1, 'sha': SHA, 'state': 'released'})
                    return result
                fixture.objects = objects
                if reason == 'ref moved':
                    fixture.branch = 'c' * 40
                if reason == 'direct scans absent':
                    fixture.data = []
                if reason == 'candidate alert open':
                    fixture.alerts = [{'number': 7}]
                def candidate_gate(args, message, *, read_only=False):
                    if args[1:2] == ['scripts/release-checks.py']:
                        self.assertEqual(args[2:], [SHA, '--candidate', '--delivery'])
                        self.assertTrue(read_only)
                        fixture.check()
                        return ''
                    return self.command(args, message)
                for phase in (PROMOTE.prepare, PROMOTE.validate, PROMOTE.final_tag, PROMOTE.publish):
                    with self.subTest(reason=reason, phase=phase.__name__), \
                            patch.object(PROMOTE, 'command', side_effect=candidate_gate):
                        with self.assertRaises(ValueError):
                            phase(TAG, SHA)
                    self.assertEqual(self.remote_tags, {})
                    self.assertTrue(self.data['prerelease'])

    def test_candidate_gate_uses_read_token_without_replacing_publication_credentials(self):
        self.mock.stop()
        with patch.dict(os.environ, GH_TOKEN='fixture-write', RELEASE_READ_TOKEN='fixture-read'), \
                patch.object(PROMOTE.subprocess, 'run', return_value=Mock(returncode=0, stdout='')) as execute:
            PROMOTE.command(['python3', 'scripts/release-checks.py', SHA, '--candidate'],
                            'checks failed', read_only=True)
            self.assertEqual(execute.call_args.kwargs['env']['GH_TOKEN'], 'fixture-read')
            self.assertEqual(os.environ['GH_TOKEN'], 'fixture-write')
            PROMOTE.command(['gh', 'release', 'edit'], 'publication failed')
            self.assertEqual(execute.call_args.kwargs['env']['GH_TOKEN'], 'fixture-write')

    def test_diagnostic_candidate_is_rejected_before_network_or_publication(self):
        with patch.object(PROMOTE, 'command') as command:
            with self.assertRaisesRegex(ValueError, 'diagnostic candidates cannot be promoted'):
                PROMOTE.source(TAG + '-diag', SHA)
            command.assert_not_called()

    def test_promotes_same_tag_and_exact_verified_bytes_without_builds_or_signing(self):
        PROMOTE.prepare(TAG, SHA)
        before = {name: (PROMOTE.directory() / name).read_bytes() for name in self.assets}
        PROMOTE.final_tag(TAG, SHA)
        PROMOTE.publish(TAG, SHA)
        self.assertEqual(before, {name: (PROMOTE.directory() / name).read_bytes() for name in self.assets})
        self.assertFalse(self.data["prerelease"])
        self.assertNotIn("<sparkle:channel>", self.feed)
        self.assertIn(f"/releases/download/{TAG}/", self.feed)
        self.assertFalse(any(args[0] in {"make", "codesign", "ditto", "zip", "xcodebuild"} for args in self.calls))

    def test_promotion_and_retry_preserve_candidate_floor_with_explicit_argument(self):
        self.feed = self.feed.replace('>26.0<', '>15.7<')
        PROMOTE.prepare(TAG, SHA)
        PROMOTE.publish(TAG, SHA)
        self.assertIn('>15.7<', self.feed)
        original = self.feed
        PROMOTE.publish(TAG, SHA)
        self.assertEqual(self.feed, original)
        updates = [args for args in self.calls if args[1] == 'scripts/update-appcast.py']
        for args in updates:
            self.assertEqual(args[args.index('--min-system') + 1], '15.7')

    def test_changed_floor_after_verification_is_rejected(self):
        PROMOTE.prepare(TAG, SHA)
        self.feed = self.feed.replace('>26.0<', '>15.7<')
        with self.assertRaisesRegex(ValueError, 'changed after provenance'):
            PROMOTE.publish(TAG, SHA)
        self.assertTrue(self.data['prerelease'])

    def test_final_tag_is_annotated_at_candidate_sha_before_release_becomes_stable(self):
        PROMOTE.prepare(TAG, SHA)
        PROMOTE.final_tag(TAG, SHA)
        self.assertEqual(self.remote_tags[f"refs/tags/{SHORT}^{{}}"], SHA)
        self.assertNotEqual(SHA, os.environ["EXPECTED_SHA"])
        self.assertTrue(self.data["prerelease"])
        PROMOTE.publish(TAG, SHA)
        self.assertEqual(self.data["tag_name"], TAG)
        self.assertFalse(self.data["prerelease"])

    def test_final_tag_rerun_accepts_peeled_candidate_without_creating_or_pushing(self):
        PROMOTE.prepare(TAG, SHA)
        PROMOTE.final_tag(TAG, SHA)
        self.assertEqual(self.remote_tags[f"refs/tags/{SHORT}^{{}}"], SHA)
        PROMOTE.publish(TAG, SHA)
        self.calls.clear()
        PROMOTE.final_tag(TAG, SHA)
        self.assertFalse(any(args[:2] in (["git", "tag"], ["git", "push"]) for args in self.calls))

    def test_conflicting_final_tag_refuses_promotion_without_replacing_it(self):
        PROMOTE.prepare(TAG, SHA)
        for target in ({f"refs/tags/{SHORT}": "c" * 40},
                       {f"refs/tags/{SHORT}": "d" * 40, f"refs/tags/{SHORT}^{{}}": "c" * 40}):
            with self.subTest(target=target):
                self.remote_tags = target.copy()
                self.calls.clear()
                with self.assertRaisesRegex(ValueError, "different commit; tags are never replaced"):
                    PROMOTE.final_tag(TAG, SHA)
                self.assertEqual(self.remote_tags, target)
                self.assertTrue(self.data["prerelease"])
                self.assertFalse(any(args[:2] in (["git", "tag"], ["git", "push"]) for args in self.calls))

    def test_final_tag_cannot_be_created_without_valid_provenance(self):
        PROMOTE.prepare(TAG, SHA)
        (PROMOTE.directory() / f"Glimmer-{SHORT}.zip").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "bytes changed"):
            PROMOTE.final_tag(TAG, SHA)
        self.assertFalse(self.remote_tags)
        self.assertFalse(self.local_tags)

    def test_final_tag_retry_pushes_existing_local_tag_and_refuses_local_conflict(self):
        PROMOTE.prepare(TAG, SHA)
        self.local_tags[SHORT] = "c" * 40
        with self.assertRaisesRegex(ValueError, "local final tag.*different commit"):
            PROMOTE.final_tag(TAG, SHA)
        self.assertFalse(self.remote_tags)
        self.local_tags[SHORT] = SHA
        self.calls.clear()
        PROMOTE.final_tag(TAG, SHA)
        self.assertEqual(self.remote_tags[f"refs/tags/{SHORT}^{{}}"], SHA)
        self.assertFalse(any(args[:3] == ["git", "tag", "-a"] for args in self.calls))

    def test_failed_tag_push_leaves_release_unpublished_and_can_retry(self):
        PROMOTE.prepare(TAG, SHA)
        real = self.command
        def failed_push(args, message, **kwargs):
            if args[:2] == ["git", "push"]:
                raise ValueError(message)
            return real(args, message, **kwargs)
        with patch.object(PROMOTE, "command", side_effect=failed_push), \
                self.assertRaisesRegex(ValueError, "cannot push final tag"):
            PROMOTE.final_tag(TAG, SHA)
        self.assertTrue(self.data["prerelease"])
        self.assertFalse(self.remote_tags)
        PROMOTE.final_tag(TAG, SHA)
        self.assertEqual(self.remote_tags[f"refs/tags/{SHORT}^{{}}"], SHA)

    def test_candidate_guard_fires_after_promotion_creates_the_final_tag(self):
        PROMOTE.prepare(TAG, SHA)
        PROMOTE.final_tag(TAG, SHA)
        PROMOTE.publish(TAG, SHA)
        config = f"MARKETING_VERSION = {SHORT}\nCURRENT_PROJECT_VERSION = {BUILD}\n"
        refs = "".join(f"{target}\t{name}\n" for name, target in self.remote_tags.items())
        with patch.object(CANDIDATE, "output", side_effect=["", "", "", config, refs]), \
                self.assertRaisesRegex(ValueError, f"{SHORT} already has a final tag; bump MARKETING_VERSION"):
            CANDIDATE.cut(False, ci_sha=SHA, pr=114)

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

    def test_malformed_sha_or_tag_is_refused_before_any_command(self):
        for tag, sha, message in ((TAG, "B" * 40, "full lowercase"), (TAG, "abc", "full lowercase"),
                                  ("2026.10.6", SHA, "invalid candidate tag"),
                                  ("2026.10.6-rc.0", SHA, "invalid candidate tag")):
            with self.subTest(tag=tag, sha=sha), self.assertRaisesRegex(ValueError, message):
                PROMOTE.source(tag, sha)
        self.assertEqual(self.calls, [])

    def test_main_that_moved_or_tag_for_another_version_is_refused(self):
        real = self.command
        moved = lambda args, message: "d" * 40 if args == ["git", "rev-parse", "origin/main"] else real(args, message)
        with patch.object(PROMOTE, "command", side_effect=moved), self.assertRaisesRegex(ValueError, "main moved"):
            PROMOTE.source(TAG, SHA)
        with self.assertRaisesRegex(ValueError, "does not match its tag"):
            PROMOTE.source("2026.10.7-rc.1", SHA)

    def test_release_must_be_published_with_exactly_one_complete_dmg_and_zip(self):
        zip_name = f"Glimmer-{SHORT}.zip"
        base = copy.deepcopy(self.data)
        for label, change, message in (
                ("draft", {"draft": True}, "not published"),
                ("tag", {"tag_name": "other"}, "not published"),
                ("missing", {"assets": self.data["assets"][:1]}, "exactly one DMG and one ZIP"),
                ("duplicate", {"assets": [*self.data["assets"], self.data["assets"][0]]}, "exactly one"),
                ("empty", {"assets": [{**a, "size": 0} if a["name"] == zip_name else a
                                      for a in self.data["assets"]]}, "incomplete"),
                ("uploading", {"assets": [{**a, "state": "starter"} for a in self.data["assets"]]}, "incomplete")):
            with self.subTest(label=label):
                self.data = {**copy.deepcopy(base), **change}
                with self.assertRaisesRegex(ValueError, message):
                    PROMOTE.release(TAG, SHORT)

    def test_feed_must_hold_this_candidate_with_matching_assets(self):
        for label, feed, message in (
                ("no channel", "<rss/>", "no channel"),
                ("other asset url", self.feed.replace(f"/{TAG}/", "/other-tag/"), "different assets"),
                ("no candidate", self.feed.replace(BUILD, "20261001"), "ValueError"),
                ("other channel", self.feed.replace(">rc<", ">beta<"), "ValueError")):
            with self.subTest(label=label):
                self.feed = feed
                with self.assertRaises(ValueError) as caught:
                    PROMOTE.feed_item(SHORT, BUILD, TAG)
                if message != "ValueError":
                    self.assertIn(message, str(caught.exception))

    def test_empty_download_or_length_mismatch_blocks_the_proof(self):
        self.assets[f"Glimmer-{SHORT}.dmg"] = b""
        with self.assertRaisesRegex(ValueError, "download is empty"):
            PROMOTE.prepare(TAG, SHA)
        self.assets[f"Glimmer-{SHORT}.dmg"] = b"dmg"
        self.feed = self.feed.replace('length="9"', 'length="999"')
        with patch.object(PROMOTE, "directory", return_value=self.root / "second"), \
                self.assertRaisesRegex(ValueError, "differs from its signed update length"):
            PROMOTE.prepare(TAG, SHA)
        self.assertFalse((self.root / "second/verified.json").exists())

    def test_run_directory_rejects_unsafe_runner_environment(self):
        for env in ({"RUNNER_TEMP": "relative"}, {"RUNNER_TEMP": str(self.root / "missing")},
                    {"GITHUB_RUN_ID": "1/../x"}, {"GITHUB_RUN_ATTEMPT": "x"}):
            with self.subTest(env=env), patch.dict(os.environ, env), self.assertRaisesRegex(ValueError, "invalid promotion"):
                PROMOTE.directory()

    def test_command_raises_the_given_message_on_nonzero_exit(self):
        self.mock.stop()
        self.addCleanup(self.mock.start)
        ok = subprocess.CompletedProcess([], 0, stdout="out", stderr="")
        bad = subprocess.CompletedProcess([], 1, stdout="", stderr="secret detail")
        with patch.object(PROMOTE.subprocess, "run", return_value=ok):
            self.assertEqual(PROMOTE.command(["x"], "failed"), "out")
        with patch.object(PROMOTE.subprocess, "run", return_value=bad), \
                self.assertRaisesRegex(ValueError, "^failed$"):
            PROMOTE.command(["x"], "failed")

    def test_main_reports_errors_on_stderr_with_exit_one_and_success_on_stdout(self):
        for phase, fails in (("prepare", True), ("validate", False), ("tag", False)):
            err, out = io.StringIO(), io.StringIO()
            fake = {"prepare": Mock(side_effect=ValueError("boom")), "validate": Mock(), "tag": Mock()}
            with patch.object(PROMOTE, "prepare", fake["prepare"]), patch.object(PROMOTE, "validate", fake["validate"]), \
                    patch.object(PROMOTE, "final_tag", fake["tag"]), \
                    patch.object(sys, "argv", ["x", phase, TAG, SHA]), \
                    contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
                if fails:
                    with self.assertRaises(SystemExit) as caught:
                        PROMOTE.main()
                    self.assertEqual(caught.exception.code, 1)
                    self.assertEqual(err.getvalue(), "ERR: boom\n")
                else:
                    PROMOTE.main()
                    self.assertIn(f"{phase} succeeded", out.getvalue())
                    fake[phase].assert_called_once_with(TAG, SHA)


if __name__ == "__main__":
    unittest.main()


class ShippedSourceTests(FixtureTestCase):
    def test_only_shipped_inputs_must_match_the_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.run(["git", "-C", directory, *args], check=True, capture_output=True,
                                      text=True, env={**os.environ, "GIT_CONFIG_GLOBAL": os.devnull}).stdout.strip()
            git("init", "-q")
            git("config", "user.email", "fixture@example.test")
            git("config", "user.name", "fixture")
            git("config", "commit.gpgsign", "false")
            shipped = ("Glimmer/App.swift", "GlimmerEngine/Native/Decoder.swift",
                       "Glimmer-Bridging-Header.h", "Glimmer/StreamLib.xcconfig",
                       "Glimmer/Assets.xcassets/icon.json", "helper/main.swift", "LoginHelper/Info.plist",
                       "Glimmer.xcodeproj/project.pbxproj",
                       "Glimmer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
                       "LICENSE", "CREDITS.md", "scripts/dmg/background.png", "scripts/provisioning.py",
                       "scripts/release_candidate_kind.py", "scripts/hitch-recording-options.json")
            unshipped = ("scripts/promote-release.py", "docs/RELEASE.md", "iOS/Glimmer/App.swift")
            for path in (*shipped, *unshipped):
                (Path(directory) / path).parent.mkdir(parents=True, exist_ok=True)
                (Path(directory) / path).write_text("one\n")
            git("add", "-A")
            git("commit", "-qm", "candidate")
            candidate = git("rev-parse", "HEAD")

            def changed(path):
                (Path(directory) / path).write_text(f"{path} changed\n")
                git("commit", "-qam", path)
                diff = subprocess.run(["git", "-C", directory, "diff", "--quiet", candidate, "HEAD", "--",
                                       *PROMOTE.SHIPPED]).returncode
                git("reset", "--hard", candidate)
                return diff != 0
            for path in unshipped:
                with self.subTest(path=path):
                    self.assertFalse(changed(path))
            for path in shipped:
                with self.subTest(path=path):
                    self.assertTrue(changed(path))
