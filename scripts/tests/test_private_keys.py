"""Exercise the offline gate with disposable keys, never signing material."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "check-private-keys.sh"
SECRET_SCRIPT = SCRIPT.with_name("check-secrets.sh")


class PrivateKeyGateTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.git("init", "-q")
        self.git("config", "--local", "commit.gpgsign", "false")
        (self.root / "README").write_text("Disposable test repository.\n")
        self.git("add", "README")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                 "commit", "-qm", "fixture")

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)

    def scan(self, **env):
        return subprocess.run(["bash", str(SCRIPT)], cwd=self.root,
                              env=self.scan_environment(**env), capture_output=True)

    def scan_environment(self, **overrides):
        environment = dict(os.environ)
        for key in ("PRE_COMMIT_FROM_REF", "PRE_COMMIT_TO_REF", "GLIMMER_SECRET_SCAN_ALL_FILES"):
            environment.pop(key, None)
        environment.update(overrides)
        return environment

    def generate_key(self):
        key = self.root / "disposable.pem"
        subprocess.run(["/usr/bin/openssl", "genrsa", "-out", str(key), "2048"],
                       check=True, capture_output=True)
        key.chmod(0o600)

    def test_ignores_untracked_keys_and_accepts_non_key_fixture_text(self):
        self.generate_key()
        (self.root / "fixture.swift").write_text(
            'let key = "-----BEGIN PRIVATE KEY-----\\nqt-key\\n-----END PRIVATE KEY-----\\n"\n')
        self.git("add", "fixture.swift")
        self.assertEqual(self.scan(PRE_COMMIT="1").returncode, 0)

    def test_staged_private_key_is_rejected_without_disclosing_it(self):
        self.generate_key()
        self.git("add", "disposable.pem")
        result = self.scan(PRE_COMMIT="1", HUSKY="1", TRUFFLEHOG_PRE_COMMIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"a private key is staged", result.stderr)
        self.assertNotIn(b"PRIVATE KEY-----", result.stdout + result.stderr)
        self.assertEqual(result.stdout, b"")

    def test_scanner_failure_is_closed_and_output_is_withheld(self):
        binary = self.root / "trufflehog"
        binary.write_text('#!/bin/bash\nprintf scanner-sensitive-output\nprintf scanner-error >&2\nexit 2\n')
        binary.chmod(0o755)
        result = self.scan(PATH=f"{self.root}:{os.environ['PATH']}")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"scan failed", result.stderr)
        self.assertNotIn(b"scanner-sensitive-output", result.stdout + result.stderr)
        self.assertNotIn(b"scanner-error", result.stdout + result.stderr)

    def test_committed_then_removed_key_is_rejected_in_review_range(self):
        base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.root).decode().strip()
        self.generate_key()
        self.git("add", "disposable.pem")
        self.commit("add disposable key")
        self.git("rm", "disposable.pem")
        self.commit("remove disposable key")
        tip = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.root).decode().strip()
        result = self.scan(GLIMMER_SECRET_SCAN_ALL_FILES="1", PRE_COMMIT_FROM_REF=base, PRE_COMMIT_TO_REF=tip)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"a private key", result.stderr)
        self.assertNotIn(b"PRIVATE KEY-----", result.stdout + result.stderr)

    def commit(self, message):
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                 "commit", "-qm", message)

    def stub_scanner(self, status=0):
        binary = self.root / "trufflehog"
        binary.write_text(
            '#!/bin/bash\n'
            'printf "%s\\n" "$@" >> "$FIXTURE_CALLS"\n'
            'if [ "$1" = filesystem ]; then\n'
            '  test -f "$2/README" || exit 2\n'
            '  test ! -L "$2/outside-link" || exit 2\n'
            '  test ! -e "$2/untracked" || exit 2\n'
            'fi\n'
            'printf scanner-sensitive-output\n'
            'printf scanner-sensitive-error >&2\n'
            f'exit {status}\n')
        binary.chmod(0o755)
        return dict(PATH=f"{self.root}:{os.environ['PATH']}", FIXTURE_CALLS=str(self.root / "calls"))

    def test_all_files_scan_uses_tracked_snapshot_without_following_symlinks(self):
        (self.root / "outside-link").symlink_to("/not-a-real-credential-path")
        self.git("add", "outside-link")
        self.commit("tracked symlink")
        (self.root / "untracked").write_text("not part of the commit")
        result = self.scan(GLIMMER_SECRET_SCAN_ALL_FILES="1", **self.stub_scanner())
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertIn("filesystem\n", calls)
        self.assertNotIn("git\n", calls)
        self.assertFalse(Path(calls.splitlines()[1]).exists())
        self.assertEqual(result.stdout + result.stderr, b"")

    def test_verified_findings_and_errors_are_withheld(self):
        for status in (183, 2):
            with self.subTest(status=status):
                result = subprocess.run(["bash", str(SECRET_SCRIPT), "verified"], cwd=self.root,
                                        env=self.scan_environment(GLIMMER_SECRET_SCAN_ALL_FILES="1",
                                                                  **self.stub_scanner(status)), capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(b"scanner-sensitive", result.stdout + result.stderr)
                self.assertEqual(result.stdout, b"")

    def test_invalid_review_range_fails_before_invoking_scanner(self):
        result = self.scan(PRE_COMMIT_FROM_REF="HEAD;anything", PRE_COMMIT_TO_REF="a" * 40,
                           **self.stub_scanner())
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "calls").exists())

    def test_local_scan_keeps_staged_scope_and_explicit_filters(self):
        result = self.scan(PRE_COMMIT="1", **self.stub_scanner())
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertIn("--since-commit\nHEAD\n--branch\nHEAD\n", calls)
        self.assertIn("--no-verification\n--results\nunverified\n", calls)

    def test_outer_hook_range_cannot_change_disposable_repository_scope(self):
        outer = dict(PRE_COMMIT="1", PRE_COMMIT_FROM_REF="b" * 40,
                     PRE_COMMIT_TO_REF="c" * 40, GLIMMER_SECRET_SCAN_ALL_FILES="1")
        with patch.dict(os.environ, outer):
            self.assertEqual(self.scan_environment()["PRE_COMMIT"], "1")
            result = self.scan(**self.stub_scanner())
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertNotIn("filesystem\n", calls)
        self.assertIn("--since-commit\nHEAD\n--branch\nHEAD\n", calls)


if __name__ == "__main__":
    unittest.main()
