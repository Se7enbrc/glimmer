# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Tap cache safety checks use isolated local fixtures and never fetch or push."""

import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tap_cache
from tap_cache import paths_alias_or_overlap, validate_cache

REPO = "fixture/homebrew-tap"


class TapCacheTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)

    def checkout(self):
        self.git("init", "-q", "--initial-branch=main")
        self.git("config", "--local", "commit.gpgsign", "false")
        self.git("remote", "add", "origin", f"git@github.com:{REPO}.git")
        (self.root / "cask.rb").write_text("fixture\n")
        self.commit()
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def commit(self):
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                 "commit", "-qm", "fixture")

    def test_new_or_empty_cache_is_allowed(self):
        validate_cache(self.root / "missing", REPO)
        validate_cache(self.root, REPO)

    def test_non_checkout_content_is_preserved(self):
        path = self.root / "valuable.txt"
        path.write_text("preserve me")
        with self.assertRaisesRegex(ValueError, "not a Git checkout"):
            validate_cache(self.root, REPO)
        self.assertEqual(path.read_text(), "preserve me")

    def test_expected_clean_checkout_is_allowed(self):
        self.checkout()
        validate_cache(self.root, REPO, "origin/main")
        for origin in (f"https://github.com/{REPO}.git", f"ssh://git@github.com/{REPO}.git"):
            self.git("remote", "set-url", "origin", origin)
            validate_cache(self.root, REPO)

    def test_wrong_origin_is_rejected(self):
        self.checkout()
        self.git("remote", "set-url", "origin", "git@github.com:someone/other.git")
        with self.assertRaisesRegex(ValueError, "origin does not match"):
            validate_cache(self.root, REPO)

    def test_wrong_push_origin_is_rejected(self):
        self.checkout()
        self.git("remote", "set-url", "--push", "origin", "git@github.com:someone/other.git")
        with self.assertRaisesRegex(ValueError, "origin does not match"):
            validate_cache(self.root, REPO)

    def test_checkout_behind_remote_can_advance(self):
        self.checkout()
        old_head = self.git("rev-parse", "HEAD").stdout.decode().strip()
        (self.root / "remote.txt").write_text("published change\n")
        self.commit()
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.git("checkout", "-q", "--detach", old_head)
        self.git("branch", "-f", "main", "HEAD")
        self.git("checkout", "-q", "main")
        validate_cache(self.root, REPO, "origin/main")

    def test_feature_branch_and_detached_head_are_preserved(self):
        self.checkout()
        self.git("checkout", "-qb", "valuable-work")
        with self.assertRaisesRegex(ValueError, "must be on main"):
            validate_cache(self.root, REPO, "origin/main")
        self.assertEqual(self.git("branch", "--show-current").stdout.strip(), b"valuable-work")
        self.git("checkout", "--detach")
        with self.assertRaisesRegex(ValueError, "must be on main"):
            validate_cache(self.root, REPO, "origin/main")

    def test_ignored_files_are_preserved_when_remote_would_replace_them(self):
        self.checkout()
        (self.root / ".gitignore").write_text("ignored\n")
        self.commit()
        (self.root / "ignored").write_text("published file\n")
        self.git("add", "-f", "ignored")
        self.commit()
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.git("checkout", "-q", "--detach", "HEAD~1")
        self.git("branch", "-f", "main", "HEAD")
        self.git("checkout", "-q", "main")
        (self.root / "ignored").write_text("valuable local file\n")
        with self.assertRaisesRegex(ValueError, "overwrite ignored files"):
            validate_cache(self.root, REPO, "origin/main")
        self.assertEqual((self.root / "ignored").read_text(), "valuable local file\n")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        validate_cache(self.root, REPO, "origin/main")

    def test_tracked_and_untracked_changes_are_preserved(self):
        self.checkout()
        for name in ("cask.rb", "untracked.txt"):
            path = self.root / name
            original = path.read_bytes() if path.exists() else None
            path.write_text("local change\n")
            with self.assertRaisesRegex(ValueError, "local changes"):
                validate_cache(self.root, REPO)
            self.assertEqual(path.read_text(), "local change\n")
            if original is None:
                path.unlink()
            else:
                path.write_bytes(original)

    def test_unpushed_commits_are_preserved(self):
        self.checkout()
        (self.root / "local.txt").write_text("local commit\n")
        self.commit()
        head = self.git("rev-parse", "HEAD").stdout
        with self.assertRaisesRegex(ValueError, "discard local commits"):
            validate_cache(self.root, REPO, "origin/main")
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, head)

    def test_filesystem_aliases_are_preserved_including_directory_conflicts(self):
        for local, incoming in (("cache", "Cache"), ("cache", "Cache/child"), ("cache/child", "Cache")):
            with self.subTest(local=local, incoming=incoming), tempfile.TemporaryDirectory() as directory:
                self.root = Path(directory)
                self.checkout()
                (self.root / ".gitignore").write_text("cache\n")
                self.commit()
                local_path = self.root / local
                local_path.parent.mkdir(exist_ok=True)
                local_path.write_text("valuable ignored file\n")
                aliases = (self.root / "Cache").exists()
                self.assertEqual(paths_alias_or_overlap(self.root, local, incoming), aliases)
                old_tree = self.git("rev-parse", "HEAD^{tree}").stdout.decode().strip()
                blob = self.git("hash-object", "-w", str(local_path)).stdout.decode().strip()
                entry = f"100644 blob {blob}\t{incoming}\n".encode()
                if "/" in incoming:
                    child = subprocess.run(["git", "-C", str(self.root), "mktree"],
                                           input=entry.replace(b"Cache/", b""), check=True,
                                           capture_output=True).stdout.decode().strip()
                    entry = f"040000 tree {child}\tCache\n".encode()
                tree = subprocess.run(["git", "-C", str(self.root), "mktree"],
                                      input=self.git("ls-tree", old_tree).stdout + entry, check=True,
                                      capture_output=True).stdout.decode().strip()
                commit = self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                                  "commit-tree", tree, "-p", "HEAD", "-m", "incoming").stdout.decode().strip()
                self.git("update-ref", "refs/remotes/origin/main", commit)
                if aliases:
                    with self.assertRaisesRegex(ValueError, "overwrite ignored files"):
                        validate_cache(self.root, REPO, "origin/main")
                else:
                    validate_cache(self.root, REPO, "origin/main")
                self.assertEqual(local_path.read_text(), "valuable ignored file\n")

    def test_a_plain_file_is_not_a_cache_directory(self):
        path = self.root / "file"
        path.write_text("keep")
        with self.assertRaisesRegex(ValueError, "not a directory"):
            validate_cache(path, REPO)
        self.assertEqual(path.read_text(), "keep")

    def test_nested_directory_inside_another_checkout_is_not_the_root(self):
        self.checkout()
        nested = self.root / "nested"
        (nested / ".git").mkdir(parents=True)
        parent = subprocess.CompletedProcess([], 0, stdout=f"{self.root}\n", stderr="")
        with patch.object(tap_cache.subprocess, "run", return_value=parent):
            with self.assertRaisesRegex(ValueError, "not the checkout root"):
                validate_cache(nested, REPO)

    def test_missing_paths_never_alias(self):
        self.assertFalse(paths_alias_or_overlap(self.root, "absent", "other"))

    def test_main_is_silent_on_success_and_exits_one_with_the_reason_on_refusal(self):
        self.checkout()
        with patch.object(sys, "argv", ["x", str(self.root), REPO, "--remote-tip", "origin/main"]):
            tap_cache.main()
        (self.root / "dirty").write_text("local")
        err = io.StringIO()
        with patch.object(sys, "argv", ["x", str(self.root), REPO]), contextlib.redirect_stderr(err), \
                self.assertRaises(SystemExit) as status:
            tap_cache.main()
        self.assertEqual(status.exception.code, 1)
        self.assertIn("ERR: tap cache has local changes", err.getvalue())

    def test_git_failure_is_reported_not_swallowed(self):
        self.checkout()
        self.git("remote", "remove", "origin")
        err = io.StringIO()
        with patch.object(sys, "argv", ["x", str(self.root), REPO]), contextlib.redirect_stderr(err), \
                self.assertRaises(SystemExit) as status:
            tap_cache.main()
        self.assertEqual(status.exception.code, 1)


if __name__ == "__main__":
    unittest.main()
