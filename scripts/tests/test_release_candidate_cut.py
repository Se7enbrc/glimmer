# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""`make rc` against a fixture origin, with inert gh, curl and open; no network or real keys."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
VERSION = "2026.10.6"
BUILD = "20261010"
REQUIRED = ["macOS", "Analyze (swift)", "Analyze (python)", "Analyze (actions)"]


def feed(*builds):
    items = "".join(f"<item><sparkle:version>{build}</sparkle:version>"
                    f"<sparkle:shortVersionString>2026.10.{index}</sparkle:shortVersionString></item>"
                    for index, build in enumerate(builds))
    return ('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
            f"{items}</channel></rss>\n")


GH = f'''#!{sys.executable}
import json, os, pathlib, sys
state = pathlib.Path(os.environ["FIXTURE_STATE"])
with (state / "gh.log").open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
runs = json.loads((state / "runs.json").read_text())
if sys.argv[1:3] == ["run", "list"]:
    print(json.dumps(runs))
elif sys.argv[1:3] == ["workflow", "run"]:
    sha = next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("expected_sha="))
    run = {{"databaseId": 100 + len(runs), "headSha": sha,
           "url": f"https://github.com/Se7enbrc/glimmer/actions/runs/{{100 + len(runs)}}"}}
    (state / "runs.json").write_text(json.dumps([run] + runs))
elif sys.argv[1] == "api":
    print((state / "check-runs.json").read_text())
elif sys.argv[1:3] == ["pr", "comment"]:
    pass
elif sys.argv[1:3] == ["pr", "view"]:
    print((state / "pr-head").read_text())
else:
    sys.exit(1)
'''


class ReleaseCandidateCutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="glimmer candidate fixture ")
        self.root = Path(self.temp.name)
        self.work, self.origin, self.state, tools = (self.root / name for name in ("work", "origin.git", "state", "bin"))
        for directory in (self.work / "scripts", self.state, tools):
            directory.mkdir(parents=True)
        self.env = {key: value for key, value in os.environ.items()
                    if key not in {"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "SSH_AUTH_SOCK"}}
        self.env.update(PATH=f"{tools}:/usr/bin:/bin", HOME=str(self.root), GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_GLOBAL=os.devnull, FIXTURE_STATE=str(self.state))
        (tools / "gh").write_text(GH)
        (tools / "curl").write_text(f'#!/bin/bash\ncat "{self.state}/live-appcast.xml"\n')
        (tools / "open").write_text(f'#!/bin/bash\necho "$@" >> "{self.state}/open.log"\n')
        for tool in tools.iterdir():
            tool.chmod(0o755)
        (self.state / "runs.json").write_text("[]")
        (self.state / "live-appcast.xml").write_text(feed("20261007", "20261008"))
        self.check_runs("completed")
        shutil.copy2(SCRIPTS / "release-candidate.py", self.work / "scripts")
        shutil.copy2(SCRIPTS / "release_validation.py", self.work / "scripts")
        (self.work / "scripts/release-checks.py").write_text(
            f"import os, runpy, sys\nREAL = runpy.run_path({str(SCRIPTS / 'release-checks.py')!r})\n"
            'REPO, REQUIRED = REAL["REPO"], REAL["REQUIRED"]\n'
            'if __name__ == "__main__" and os.environ.get("FIXTURE_CHECKS"):\n'
            '    sys.exit("ERR: " + os.environ["FIXTURE_CHECKS"])\n')
        (self.work / "Glimmer").mkdir()
        (self.work / "appcast.xml").write_text(feed("20261008"))
        (self.work / ".gitignore").write_text("__pycache__/\n")
        self.git("init", "--quiet", "--bare", str(self.origin), cwd=self.root)
        self.git("init", "--quiet", "-b", "feat/rc")
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "fixture", "-f", str(self.root / "key")],
                       check=True, env=self.env, capture_output=True)
        for key, value in (("user.name", "Fixture"), ("user.email", "fixture@example.test"),
                           ("gpg.format", "ssh"), ("user.signingkey", str(self.root / "key")),
                           ("remote.origin.url", str(self.origin)),
                           ("remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")):
            self.git("config", key, value)
        self.old = self.commit("20261009")
        self.sha = self.commit(BUILD)
        self.git("push", "--quiet", "origin", "HEAD:refs/heads/feat/rc")

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd or self.work, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, build):
        (self.work / "Glimmer/Version.xcconfig").write_text(
            f"MARKETING_VERSION = {VERSION}\nCURRENT_PROJECT_VERSION = {build}\n")
        self.git("add", "-A")
        self.git("commit", "--quiet", "-m", f"build {build}")
        return self.git("rev-parse", "HEAD")

    def check_runs(self, status, conclusion="success"):
        runs = [{"id": index, "name": name, "status": status, "conclusion": conclusion}
                for index, name in enumerate(REQUIRED)]
        (self.state / "check-runs.json").write_text(json.dumps([{"check_runs": runs}]))

    def tag_origin(self, *names, sha=None):
        for name in names:
            self.git("push", "--quiet", "origin", f"{sha or self.old}:refs/tags/{name}")

    def remote(self):
        return self.git("ls-remote", "origin")

    def cut(self, *args, **env):
        return subprocess.run([sys.executable, str(self.work / "scripts/release-candidate.py"), *args],
                              cwd=self.work, env={**self.env, **env}, capture_output=True, text=True, timeout=60)

    def gh_calls(self):
        log = self.state / "gh.log"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def dispatches(self):
        return [call for call in self.gh_calls() if call[:2] == ["workflow", "run"]]

    def assert_refused(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertEqual(self.dispatches(), [])

    def test_dirty_tree_is_refused(self):
        (self.work / "notes.txt").write_text("untracked\n")
        before = self.remote()
        self.assert_refused(self.cut(), "working tree is not clean")
        self.assertEqual(self.remote(), before)

    def test_unpushed_head_is_refused(self):
        self.commit("20261011")
        self.assert_refused(self.cut(), "is not pushed")

    def test_stale_build_number_is_refused(self):
        (self.state / "live-appcast.xml").write_text(feed("20261008", BUILD))
        self.assert_refused(self.cut(), f"must exceed published build {BUILD}")

    def test_unreachable_live_appcast_falls_back_to_committed_one(self):
        (self.state / "live-appcast.xml").unlink()
        result = self.cut("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("checking the committed appcast.xml", result.stderr)

    def test_existing_final_tag_is_refused(self):
        self.tag_origin(VERSION)
        self.assert_refused(self.cut(), "already has a final tag")

    def test_first_candidate_is_rc1(self):
        self.assertIn(f"Candidate {VERSION}-rc.1:", self.cut("--dry-run").stdout)

    def test_cut_numbers_after_highest_rc_ignoring_legacy_tags_then_signs_moves_and_dispatches(self):
        self.tag_origin(f"{VERSION}-rc.1", f"{VERSION}-rc.2", f"{VERSION}-rc9", "2026.7.8-rc2")
        result = self.cut()
        self.assertEqual(result.returncode, 0, result.stderr)
        tag = f"{VERSION}-rc.3"
        remote = self.remote()
        self.assertIn(f"{self.sha}\trefs/heads/release-candidate", remote)
        self.assertIn(f"{self.sha}\trefs/tags/{tag}^{{}}", remote)
        self.assertIn("-----BEGIN SSH SIGNATURE-----", self.git("cat-file", "tag", tag))
        self.assertEqual(self.dispatches(), [["workflow", "run", "release.yml", "--ref", "release-candidate",
                                              "-f", "operation=candidate", "-f", f"expected_sha={self.sha}",
                                              "-f", f"rc_tag={tag}"]])
        url = "https://github.com/Se7enbrc/glimmer/actions/runs/100"
        self.assertIn(f"Release run: {url}", result.stdout)
        self.assertIn("approve the protected `release` deployment", result.stdout)
        self.assertEqual((self.state / "open.log").read_text().strip(), url)
        again = self.cut()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn(f"{tag} already identifies {self.sha}", again.stdout)
        self.assertEqual(len(self.dispatches()), 1)

    def test_ci_cut_tags_as_the_app_and_comments_the_run_on_the_pull_request(self):
        self.git("checkout", "--quiet", "--detach", self.sha)
        (self.work / "untracked-ci-file").write_text("runner state\n")
        (self.state / "pr-head").write_text(self.sha)
        result = self.cut("--ci-sha", self.sha, "--pr", "114")
        self.assertEqual(result.returncode, 0, result.stderr)
        tag = f"{VERSION}-rc.1"
        self.assertIn(f"{self.sha}\trefs/tags/{tag}^{{}}", self.remote())
        self.assertNotIn("SIGNATURE", self.git("cat-file", "tag", tag))
        url = "https://github.com/Se7enbrc/glimmer/actions/runs/100"
        comments = [call for call in self.gh_calls() if call[:2] == ["pr", "comment"]]
        self.assertEqual(len(comments), 1)
        self.assertEqual(comments[0][2], "114")
        self.assertIn(url, comments[0][4])
        self.assertFalse((self.state / "open.log").exists())

    def test_ci_cut_refuses_once_the_pull_request_moves_on(self):
        self.git("checkout", "--quiet", "--detach", self.sha)
        (self.state / "pr-head").write_text(self.old)
        self.assert_refused(self.cut("--ci-sha", self.sha, "--pr", "114"), "moved past")
        self.assertNotIn("refs/tags/", self.remote())

    def test_ci_wait_only_waits_and_changes_nothing(self):
        self.git("checkout", "--quiet", "--detach", self.sha)
        before = self.remote()
        result = self.cut("--ci-sha", self.sha, "--pr", "114", "--wait-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Required checks passed for {self.sha}", result.stdout)
        self.assertEqual(self.remote(), before)
        self.assertEqual(self.dispatches(), [])

    def test_ci_cut_refuses_a_checkout_that_is_not_the_labelled_head(self):
        self.assert_refused(self.cut("--ci-sha", self.old, "--pr", "114"), "checkout is not the pull request head")
        self.assertNotEqual(self.cut("--ci-sha", "abc", "--pr", "114").returncode, 0)

    def test_tag_on_another_commit_is_refused(self):
        self.git("tag", f"{VERSION}-rc.1", self.old)
        self.assert_refused(self.cut(), "tags are never replaced")
        self.assertNotIn("refs/tags/", self.remote())

    def test_dry_run_changes_nothing(self):
        before = (self.remote(), self.git("for-each-ref"))
        result = self.cut("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.remote(), self.git("for-each-ref")), before)
        self.assertEqual(self.dispatches(), [])
        self.assertFalse((self.state / "open.log").exists())
        for line in (f"Would run: git push origin {self.sha}:refs/heads/release-candidate",
                     f"Would run: git tag -s {VERSION}-rc.1 {self.sha} -m {VERSION}-rc.1",
                     f"Would run: git push origin refs/tags/{VERSION}-rc.1",
                     "Would run: gh workflow run release.yml --ref release-candidate -f operation=candidate"):
            self.assertIn(line, result.stdout)

    def test_non_fast_forward_moves_branch_with_lease(self):
        self.git("checkout", "--quiet", "-b", "older", self.old)
        diverged = self.commit("20261099")
        self.git("push", "--quiet", "origin", f"{diverged}:refs/heads/release-candidate")
        self.git("checkout", "--quiet", "feat/rc")
        result = self.cut()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"git push --force-with-lease=release-candidate:{diverged} origin", result.stdout)
        self.assertIn(f"Moved release-candidate from {diverged[:12]} to {self.sha[:12]}", result.stdout)
        self.assertIn(f"{self.sha}\trefs/heads/release-candidate", self.remote())

    def test_failed_checks_stop_without_waiting(self):
        self.check_runs("completed", "failure")
        result = self.cut(FIXTURE_CHECKS="job is not green: macOS")
        self.assert_refused(result, "required checks failed")
        self.assertIn("job is not green: macOS", result.stderr)
        self.assertNotIn("release-candidate", self.remote())

    def test_make_target_passes_dry_run(self):
        plan = subprocess.run(["make", "--dry-run", "rc", "DRY_RUN=1"], cwd=SCRIPTS.parent,
                              env=self.env, capture_output=True, text=True, check=True).stdout
        self.assertIn("scripts/release-candidate.py --dry-run", plan)


if __name__ == "__main__":
    unittest.main()
