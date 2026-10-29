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
        self.source = (ROOT / ".github/workflows/dco.yml").read_text()
        self.requirement_shell = self.step_shell("Determine DCO requirement")
        self.check_shell = self.step_shell("Check author sign-offs")
        gh = self.root / "gh"
        gh.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$FIXTURE_GH_ARGS"\n'
                      'printf "%s\\n" "$FIXTURE_PERMISSION"\nexit "$FIXTURE_API_STATUS"\n')
        gh.chmod(0o755)
        self.env["PATH"] = f"{self.root}:{self.env['PATH']}"

    def step_shell(self, name):
        step = self.source.split(f"      - name: {name}\n", 1)[1].split("\n      - name:", 1)[0]
        return textwrap.dedent(step.split("        run: |\n", 1)[1])

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

    def check(self, head, passes, base=None, association="NONE", permission="read", api_status="0"):
        event = self.root / "event.json"
        event.write_text(json.dumps({"pull_request": {
            "base": {"sha": base or self.base}, "head": {"sha": head},
            "user": {"login": "pr-author"}, "author_association": association,
        }}))
        output = self.root / "output"
        output.write_text("")
        arguments = self.root / "gh-arguments"
        env = {**self.env, "GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output),
               "GITHUB_REPOSITORY": "fixture/repo", "GITHUB_ACTOR": "unrelated-maintainer",
               "FIXTURE_GH_ARGS": str(arguments), "FIXTURE_PERMISSION": permission,
               "FIXTURE_API_STATUS": api_status}
        result = run_fixture(["bash", "-euo", "pipefail", "-c", self.requirement_shell], cwd=self.root, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(arguments.read_text().splitlines(), [
            "api", "--method", "GET", "repos/fixture/repo/collaborators/pr-author/permission",
            "--jq", ".permission",
        ])
        self.assertIn(output.read_text(), ("required=true\n", "required=false\n"))
        if output.read_text() == "required=true\n":
            result = run_fixture(["bash", "-euo", "pipefail", "-c", self.check_shell], cwd=self.root, env=env)
        else:
            self.assertIn("DCO passed:", result.stdout)
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

    def test_commit_author_identity_cannot_exempt_an_external_pr(self):
        for author in (
            ("Se7enbrc", "33919853+Se7enbrc@users.noreply.github.com"),
            ("ugfuglio", "se7en.brc@gmail.com"),
        ):
            with self.subTest(author=author):
                self.check(self.commit("Change", author, (self.base,)), False)

    def test_write_or_higher_permission_exempts_the_entire_pr(self):
        first = self.commit("Unsigned change", parents=(self.base,))
        head = self.commit("Another unsigned author", ("Other", "other@example.com"), (first,))
        for permission in ("admin", "maintain", "write"):
            with self.subTest(permission=permission):
                self.check(head, True, permission=permission)

    def test_read_only_permission_overrides_privileged_association(self):
        head = self.commit("Unsigned change", parents=(self.base,))
        for permission in ("read", "triage", "none"):
            for association in ("OWNER", "MEMBER", "COLLABORATOR"):
                with self.subTest(permission=permission, association=association):
                    self.check(head, False, association=association, permission=permission)

    def test_unavailable_or_unrecognized_permission_falls_back_to_association(self):
        head = self.commit("Unsigned change", parents=(self.base,))
        for api_status, permission in (("1", ""), ("0", "null"), ("0", "")):
            for association in ("OWNER", "MEMBER", "COLLABORATOR", "CONTRIBUTOR",
                                "FIRST_TIME_CONTRIBUTOR", "FIRST_TIMER", "NONE", None):
                with self.subTest(status=api_status, permission=permission, association=association):
                    passes = association in ("OWNER", "MEMBER", "COLLABORATOR")
                    self.check(head, passes, association=association, permission=permission, api_status=api_status)

    def test_exempt_pr_succeeds_without_commit_history(self):
        self.check("unavailable", True, permission="write")
        job = self.source.split("  dco:\n", 1)[1].split("    steps:\n", 1)[0]
        self.assertIn("    name: DCO\n", job)
        self.assertNotIn("    if:", job)
        requirement = self.source.split("      - name: Determine DCO requirement\n", 1)[1]
        self.assertNotIn("        if:", requirement.split("\n      - name:", 1)[0])
        for name in ("Check out commit history", "Check author sign-offs"):
            step = self.source.split(f"      - name: {name}\n", 1)[1].split("\n      - name:", 1)[0]
            self.assertIn("        if: steps.requirement.outputs.required == 'true'", step)

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
