"""GitHub commit requests use inert responses and disposable metadata only."""

import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from github_signed_commit import commit_file

HEAD = "a" * 40
COMMIT = "b" * 40


def response(signature=None, **fields):
    commit = {"oid": COMMIT, "signature": signature or {"isValid": True, "wasSignedByGitHub": True}}
    return json.dumps({"data": {"createCommitOnBranch": {"commit": commit}}, **fields})


class GitHubSignedCommitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.file = Path(self.temp.name) / "metadata"
        self.file.write_bytes(b'quote " slash \\ line\n\xc3\xa9\x00')

    def commit(self, repository="Se7enbrc/glimmer", head=HEAD, path="appcast.xml"):
        return commit_file(repository, head, path, self.file, 'appcast: "fixture"')

    def test_typed_json_preserves_bytes_expected_head_and_repository(self):
        with patch("github_signed_commit.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, response(), "")
            self.assertEqual(self.commit(), COMMIT)
        self.assertEqual(run.call_args.args[0], ["gh", "api", "graphql", "--input", "-"])
        request = json.loads(run.call_args.kwargs["input"])
        data = request["variables"]["input"]
        self.assertEqual(data["expectedHeadOid"], HEAD)
        self.assertEqual(data["branch"], {"repositoryNameWithOwner": "Se7enbrc/glimmer", "branchName": "main"})
        self.assertEqual(data["message"]["headline"], 'appcast: "fixture"')
        self.assertEqual(len(data["fileChanges"]["additions"]), 1)
        change = data["fileChanges"]["additions"][0]
        self.assertEqual(change["path"], "appcast.xml")
        self.assertEqual(base64.b64decode(change["contents"]), self.file.read_bytes())
        self.assertTrue(run.call_args.kwargs["capture_output"])
        self.assertEqual(run.call_args.kwargs["timeout"], 60)

    def test_explicit_fork_repository_is_preserved(self):
        with patch("github_signed_commit.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, response(), "")
            self.commit(repository="fixture-fork/homebrew-glimmer", path="Casks/glimmer.rb")
        data = json.loads(run.call_args.kwargs["input"])["variables"]["input"]
        self.assertEqual(data["branch"]["repositoryNameWithOwner"], "fixture-fork/homebrew-glimmer")
        self.assertEqual(data["fileChanges"]["additions"][0]["path"], "Casks/glimmer.rb")

    def test_invalid_request_fails_before_network(self):
        for kwargs in ({"repository": "https://github.com/owner/repo"}, {"head": "main"},
                       {"path": "../secret"}, {"path": "/secret"}, {"path": "a//b"}):
            with self.subTest(kwargs=kwargs), patch("github_signed_commit.subprocess.run") as run:
                with self.assertRaises(ValueError):
                    self.commit(**kwargs)
                run.assert_not_called()

    def test_invalid_or_non_github_signature_never_reports_success(self):
        for signature in ({"isValid": False, "wasSignedByGitHub": True},
                          {"isValid": True, "wasSignedByGitHub": False},
                          {"isValid": "true", "wasSignedByGitHub": True}):
            with self.subTest(signature=signature), patch("github_signed_commit.subprocess.run") as run:
                run.return_value = subprocess.CompletedProcess([], 0, response(signature), "")
                with self.assertRaisesRegex(ValueError, "remote may already have changed"):
                    self.commit()
                self.assertEqual(run.call_count, 1)

    def test_api_errors_and_malformed_results_withhold_response_and_do_not_retry(self):
        for status, output in ((1, "private server detail"), (0, "private server detail"),
                               (0, response(errors=[{"message": "private server detail"}])),
                               (0, '{"data":{"createCommitOnBranch":{"commit":null}}}')):
            with self.subTest(status=status, output=output), patch("github_signed_commit.subprocess.run") as run:
                run.return_value = subprocess.CompletedProcess([], status, output, "private server detail")
                with self.assertRaises(ValueError) as raised:
                    self.commit()
                self.assertNotIn("private server detail", str(raised.exception))
                self.assertEqual(run.call_count, 1)

    def test_timeout_reports_ambiguous_remote_state_without_details(self):
        with patch("github_signed_commit.subprocess.run") as run:
            run.side_effect = subprocess.TimeoutExpired("gh", 60, output="private detail")
            with self.assertRaisesRegex(ValueError, "may have changed") as raised:
                self.commit()
        self.assertNotIn("private detail", str(raised.exception))


TAP_TOOL = r'''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["FIXTURE_LOG"], "a") as log:
    log.write(json.dumps({"tool": name, "args": args}) + "\n")
if name == "git":
    args = args[2:]
    if args[0] == "rev-parse":
        print("a" * 40)
    elif args[0] == "show":
        print("MARKETING_VERSION = 2026.10.6")
    elif args[0] == "diff":
        sys.exit(1)
elif name == "gh":
    state = pathlib.Path(os.environ["FIXTURE_LOG"] + ".release")
    if args[:2] == ["release", "create"]:
        state.write_text("true" if "--draft" in args else "false")
    elif args[:2] == ["release", "edit"] and "--draft=false" in args:
        state.write_text("false")
    elif args[:2] == ["release", "view"] and os.environ.get("FIXTURE_NEW_RELEASE") and not state.exists():
        sys.exit(1)
    elif args[:2] == ["release", "view"] and "databaseId" in args:
        print(7)
    elif args[0] == "api" and args[1].endswith("/releases/7") and ".draft" in args:
        print(state.read_text() if state.exists() else "false")
    elif args[:2] == ["release", "view"] and "--json" in args:
        print("false" if os.environ.get("FIXTURE_PRERELEASE") else "true")
    elif args[:2] == ["release", "download"]:
        (pathlib.Path(args[args.index("-D") + 1]) / "Glimmer-2026.10.6.dmg").write_bytes(b"fixture")
    elif args[:2] == ["api", "graphql"]:
        pathlib.Path(os.environ["FIXTURE_REQUEST"]).write_text(sys.stdin.read())
        if os.environ.get("FIXTURE_GRAPHQL_FAILURE"):
            print("private GraphQL failure detail", file=sys.stderr)
            sys.exit(1)
        print(json.dumps({"data": {"createCommitOnBranch": {"commit": {
            "oid": "b" * 40, "signature": {"isValid": True, "wasSignedByGitHub": True}}}}}))
elif name == "ditto":
    pathlib.Path(args[-1]).write_bytes(b"fixture zip")
'''


class HomebrewCommitPathTests(unittest.TestCase):
    def test_hosted_uses_signed_api_while_local_keeps_normal_git_commits(self):
        import hashlib
        for hosted, tag, prerelease in ((False, "2026.10.6", False), (True, "2026.10.6", False),
                                       (True, "2026.10.6-rc.1", False), (True, "2026.10.6-rc.1", True)):
            with self.subTest(hosted=hosted, tag=tag, prerelease=prerelease), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name in ("scripts", "bin", "tap/.git", "tap/Casks"):
                    (root / name).mkdir(parents=True)
                for name in ("homebrew-bump.sh", "github_signed_commit.py"):
                    shutil.copy2(SCRIPTS / name, root / "scripts" / name)
                (root / "scripts/tap_cache.py").write_text("pass\n")
                digest = hashlib.sha256(b"fixture").hexdigest()
                (root / "tap/Casks/glimmer.rb").write_text(
                    f'  version "2026.10.6"\n  sha256 "{digest}"\n'
                    '  url "https://github.com/fork/glimmer/releases/download/#{version}/Glimmer-#{version}.dmg"\n'
                    '  app "Glimmer.app"\n'
                    '  binary "#{appdir}/Glimmer.app/Contents/MacOS/Glimmer", target: "glimmer"\n')
                for name in ("git", "gh"):
                    tool = root / "bin" / name
                    tool.write_text(f"#!{sys.executable}\n" + TAP_TOOL)
                    tool.chmod(0o755)
                (root / "bin/python3").symlink_to(sys.executable)
                log, request = root / "calls", root / "request"
                env = {"PATH": f"{root / 'bin'}:/usr/bin:/bin", "HOME": str(root),
                       "GLIMMER_TAP_CACHE": str(root / "tap"), "TAP_REPO": "fork/homebrew-glimmer",
                       "RELEASES_REPO": "fork/glimmer", "FIXTURE_LOG": str(log),
                       "FIXTURE_REQUEST": str(request), "GITHUB_ACTIONS": "true" if hosted else "false"}
                if prerelease:
                    env["FIXTURE_PRERELEASE"] = "1"
                result = subprocess.run(["bash", str(root / "scripts/homebrew-bump.sh"), "2026.10.6", tag],
                                        env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, not prerelease, result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                if prerelease:
                    self.assertFalse(request.exists())
                    self.assertFalse(any(call["args"][:2] == ["release", "download"] for call in calls))
                    continue
                self.assertIn(f'/releases/download/{tag}/Glimmer-#{{version}}.dmg',
                              (root / "tap/Casks/glimmer.rb").read_text())
                commands = [call["args"][2] for call in calls if call["tool"] == "git"]
                self.assertEqual("commit" in commands, not hosted)
                self.assertEqual("push" in commands, not hosted)
                self.assertEqual(request.exists(), hosted)
                if hosted:
                    data = json.loads(request.read_text())["variables"]["input"]
                    self.assertEqual(data["expectedHeadOid"], HEAD)
                    self.assertEqual(data["branch"]["repositoryNameWithOwner"], "fork/homebrew-glimmer")
                    self.assertEqual(base64.b64decode(data["fileChanges"]["additions"][0]["contents"]),
                                     (root / "tap/Casks/glimmer.rb").read_bytes())


class AppcastCommitPathTests(unittest.TestCase):
    def test_appcast_commits_after_release_with_cas_and_no_unsigned_fallback(self):
        for hosted, failure in ((False, False), (True, False), (True, True)):
            with self.subTest(hosted=hosted, failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name in ("scripts", "bin", "tools", "dist", "Glimmer", "Glimmer.app/Contents"):
                    (root / name).mkdir(parents=True)
                for name in ("publish-release.sh", "github_signed_commit.py"):
                    shutil.copy2(SCRIPTS / name, root / "scripts" / name)
                (root / "Glimmer/Version.xcconfig").write_text("MARKETING_VERSION = 2026.10.6\n")
                (root / "Glimmer.app/Contents/Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleShortVersionString": "2026.10.6", "CFBundleVersion": "400"}))
                (root / "dist/Glimmer-2026.10.6.dmg").write_bytes(b"fixture")
                (root / "dist/Glimmer-2026.10.6.zip").write_bytes(b"fixture zip")
                original_feed = b"<rss>original</rss>\n"
                (root / "appcast.xml").write_bytes(original_feed)
                (root / "scripts/release_validation.py").write_text("pass\n")
                root.joinpath("scripts/verify-update-signature.swift").write_text("#!/bin/sh\nexit 0\n")
                root.joinpath("scripts/verify-update-signature.swift").chmod(0o755)
                (root / "scripts/update-appcast.py").write_text(
                    f'#!{sys.executable}\nimport pathlib, sys\n'
                    'pathlib.Path(sys.argv[1]).write_text("<rss>fixture</rss>\\n")\n')
                (root / "scripts/update-appcast.py").chmod(0o755)
                for name in ("git", "gh", "make", "ditto"):
                    tool = root / "bin" / name
                    tool.write_text(f"#!{sys.executable}\n" + TAP_TOOL)
                    tool.chmod(0o755)
                stubs = {
                    "scripts/signing-creds.sh": 'printf "inert-signing-fixture\\n"\n',
                    "scripts/sparkle-tools.sh": 'printf "%s\\n" "$FIXTURE_TOOLS"\n',
                    "tools/sign_update": "cat >/dev/null\nprintf 'sparkle:edSignature=\"fixture\" length=\"11\"\\n'\n",
                }
                for name, source in stubs.items():
                    path = root / name
                    path.write_text("#!/bin/bash\n" + source)
                    path.chmod(0o755)
                (root / "bin/python3").symlink_to(sys.executable)
                log, request = root / "calls", root / "request"
                env = {"PATH": f"{root / 'bin'}:/usr/bin:/bin", "HOME": str(root),
                       "FIXTURE_LOG": str(log), "FIXTURE_REQUEST": str(request),
                       "FIXTURE_TOOLS": str(root / "tools"), "FIXTURE_NEW_RELEASE": "1",
                       "GITHUB_ACTIONS": "true" if hosted else "false"}
                if failure:
                    env["FIXTURE_GRAPHQL_FAILURE"] = "1"
                result = subprocess.run(["bash", str(root / "scripts/publish-release.sh"), "2026.10.6",
                                         "400", str(root / "Glimmer.app"), str(root / "dist"), "fork/glimmer"],
                                        env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, not failure, result.stderr)
                self.assertNotIn("private GraphQL failure detail", result.stdout + result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                commands = [call["args"][2] for call in calls if call["tool"] == "git"]
                self.assertEqual("commit" in commands, not hosted)
                self.assertEqual("push" in commands, not hosted)
                if hosted:
                    data = json.loads(request.read_text())["variables"]["input"]
                    self.assertEqual(data["expectedHeadOid"], HEAD)
                    self.assertEqual(data["branch"]["repositoryNameWithOwner"], "fork/glimmer")
                    self.assertEqual(data["fileChanges"]["additions"][0]["path"], "appcast.xml")
                    self.assertEqual(base64.b64decode(data["fileChanges"]["additions"][0]["contents"]),
                                     b"<rss>fixture</rss>\n")
                    self.assertEqual((root / "appcast.xml").read_bytes(), original_feed)
                    creation = next(index for index, call in enumerate(calls)
                                    if call["tool"] == "gh" and call["args"][:2] == ["release", "create"])
                    mutations = [index for index, call in enumerate(calls)
                                 if call["tool"] == "gh" and call["args"][:2] == ["api", "graphql"]]
                    self.assertEqual(len(mutations), 1)
                    self.assertLess(creation, mutations[0])
