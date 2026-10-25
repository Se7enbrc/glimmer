# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

import json
import os
from pathlib import Path
import tempfile
import textwrap
import unittest

from fixture_process import run_fixture

ROOT = Path(__file__).resolve().parents[2]
AUTHOR = ("Contributor", "contributor@example.com")
SIGN_OFF = "Signed-off-by: Contributor <contributor@example.com>"


class DCOTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.git("init", "--quiet")
        self.tree = self.git("mktree", input="").strip()
        self.base = self.commit("Base without sign-off")
        source = (ROOT / ".github/workflows/dco.yml").read_text()
        self.shell = textwrap.dedent(source.split("        run: |\n", 1)[1])

    def git(self, *args, input=None, env=None):
        with tempfile.TemporaryFile(mode="w+") as input_file:
            input_file.write(input or "")
            input_file.seek(0)
            result = run_fixture(["git", *args], stdin=input_file, cwd=self.root, env=env or self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def commit(self, message, author=AUTHOR, parents=()):
        env = {**self.env, "GIT_AUTHOR_NAME": author[0], "GIT_AUTHOR_EMAIL": author[1],
               "GIT_COMMITTER_NAME": "Committer", "GIT_COMMITTER_EMAIL": "committer@example.com"}
        arguments = ["commit-tree", self.tree]
        for parent in parents:
            arguments.extend(["-p", parent])
        return self.git(*arguments, input=message, env=env).strip()

    def check(self, head, passes, base=None):
        event = self.root / "event.json"
        event.write_text(json.dumps({"pull_request": {
            "base": {"sha": base or self.base}, "head": {"sha": head},
        }}))
        env = {**self.env, "GITHUB_EVENT_PATH": str(event)}
        result = run_fixture(["bash", "-euo", "pipefail", "-c", self.shell], cwd=self.root, env=env)
        self.assertEqual(result.returncode, 0 if passes else 1, result.stdout + result.stderr)
        return result

    def test_requires_a_matching_author_trailer(self):
        for trailer, passes in (
            (SIGN_OFF, True),
            ("", False),
            ("Signed-off-by: Other <contributor@example.com>", False),
            ("Signed-off-by: Contributor <other@example.com>", False),
            ("Signed-off-by: Committer <committer@example.com>", False),
            ("Signed-off-by: Other <other@example.com>\n" + SIGN_OFF, True),
            (SIGN_OFF + "\n\nA later paragraph makes that body text.", False),
            ("Quoted example: " + SIGN_OFF, False),
        ):
            with self.subTest(trailer=trailer):
                head = self.commit("Change\n\n" + trailer, parents=(self.base,))
                self.check(head, passes)

    def test_owner_exemption_requires_both_a_known_name_and_email(self):
        for author, passes in (
            (("Se7enbrc", "33919853+Se7enbrc@users.noreply.github.com"), True),
            (("ugfuglio", "se7en.brc@gmail.com"), True),
            (("Se7enbrc", "se7en.brc@gmail.com"), True),
            (("ugfuglio", "33919853+Se7enbrc@users.noreply.github.com"), True),
            (("Se7enbrc", AUTHOR[1]), False),
            ((AUTHOR[0], "se7en.brc@gmail.com"), False),
        ):
            with self.subTest(author=author):
                self.check(self.commit("Change", author, (self.base,)), passes)

    def test_checks_earlier_commits_and_all_merge_parents(self):
        unsigned = self.commit("Unsigned change", parents=(self.base,))
        signed = self.commit("Signed change\n\n" + SIGN_OFF, parents=(unsigned,))
        result = self.check(signed, False)
        self.assertIn(unsigned, result.stdout)
        branch = self.commit("Signed branch\n\n" + SIGN_OFF, parents=(self.base,))
        merge = self.commit("Signed merge\n\n" + SIGN_OFF, parents=(branch, unsigned))
        self.check(merge, False)

    def test_checks_pr_head_without_the_synthetic_merge_or_base_commits(self):
        head = self.commit("Change\n\n" + SIGN_OFF, parents=(self.base,))
        merge = self.commit("Unsigned synthetic merge", parents=(self.base, head))
        self.git("update-ref", "refs/heads/checkout", merge)
        self.git("symbolic-ref", "HEAD", "refs/heads/checkout")
        self.check(head, True)

    def test_empty_missing_and_malformed_ranges_fail_closed(self):
        self.check(self.base, False)
        self.check("0" * 40, False)
        self.check("--all", False)
        self.check(self.base, False, base="--all")
