# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Release workflow trust and credential guards with inert tools and fixture values."""

import re
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

from fixture_git import FixtureTestCase


class ReleaseWorkflowTests(FixtureTestCase):
    def test_publication_receives_every_secret_it_reads(self):
        # A called workflow sees an environment secret only if the caller passes it.
        root = Path(__file__).resolve().parents[2] / ".github/workflows"
        called = (root / "release-publication.yml").read_text()
        caller = (root / "release.yml").read_text()
        used = set(re.findall(r"secrets\.([A-Z_]+)", called))
        declared = set(re.findall(r"^      ([A-Z_]+):\n        required: false$", called, re.M))
        call = re.split(r"\n  [a-z][a-z_-]*:\n", caller.split("uses: ./.github/workflows/release-publication.yml", 1)[1])[0]
        passed = set(re.findall(r"^      ([A-Z_]+):\s+\$\{\{ secrets\.([A-Z_]+) \}\}$", call, re.M))
        self.assertTrue(used)
        self.assertEqual(used, declared)
        self.assertEqual({name for name, _ in passed}, used)
        self.assertTrue(all(name == source for name, source in passed))
        self.assertNotIn("secrets: inherit", caller)

    def test_verification_jobs_are_independent_unsigned_and_bound_to_the_dispatch_sha(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/release.yml").read_text()
        for part in ("checks", "tests", "asan"):
            with self.subTest(part=part):
                start = workflow.index(f"  verify-{part}:\n")
                next_job = workflow.find("\n  verify-", start + 1)
                end = next_job if next_job != -1 else workflow.index("\n  build:", start)
                job = workflow[start:end]
                required = ["ref: ${{ github.sha }}", "EXPECTED_SHA: ${{ inputs.expected_sha }}",
                            "record: ${{ steps.verify.outputs.record }}",
                            f"runs-on: {'ubuntu-24.04' if part == 'checks' else 'macos-26'}"]
                if part != "checks":
                    required += ["DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer",
                                 "SWIFT_TREAT_WARNINGS_AS_ERRORS = YES", "GCC_TREAT_WARNINGS_AS_ERRORS = YES"]
                for value in required:
                    self.assertIn(value, job)
                for forbidden in ("needs:", "environment:", "secrets.", "id-token:", "attestations:"):
                    self.assertNotIn(forbidden, job)
                self.assertLess(job.index("scripts/ci-release.sh checks"), job.index(f"ci-release.sh verify-{part}"))

    def test_build_requires_every_job_and_has_no_secrets(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/release.yml").read_text()
        job = workflow.split("\n  build:\n", 1)[1].split("\n  sign:", 1)[0]
        self.assertIn("needs: [verify-checks, verify-tests, verify-asan]", job)
        for part in ("checks", "tests", "asan"):
            self.assertIn(f"needs.verify-{part}.result == 'success'", " ".join(job.split()))
            self.assertIn(f"VERIFY_{part.upper()}_RECORD:", job)
        for forbidden in ("environment:", "secrets.", "id-token:", "attestations:"):
            self.assertNotIn(forbidden, job)
        self.assertLess(job.index("scripts/ci-release.sh verified"), job.index("scripts/ci-release.sh build"))

    def test_signer_uses_main_and_publication_is_separate(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/release.yml").read_text()
        sign = workflow.split("\n  sign:\n")[1].split("\n  validate:")[0]
        self.assertIn("environment: release", sign)
        self.assertIn("ref: main", sign)
        self.assertNotIn("ref: ${{ needs.tooling.outputs.sha }}", workflow)
        self.assertLess(sign.index("import-unsigned"), sign.index("ci-release.sh sign"))
        self.assertNotIn("ci-release.sh build", sign)
        self.assertNotIn("RELEASE_CONTENTS_TOKEN", sign)
        self.assertLess(sign.index("ci-release.sh sign"), sign.index("ci-release.sh package"))
        self.assertLess(sign.index("ci-release.sh package"), sign.index("- name: Attest final release assets"))
        self.assertLess(sign.index("- name: Attest final release assets"), sign.index("release_publication.py persist"))
        validation = workflow.split("\n  validate:\n")[1].split("\n  publication:")[0]
        self.assertNotIn("environment:", validation)
        self.assertNotIn("secrets.", validation)
        self.assertNotIn("id-token:", validation)
        self.assertIn('release_publication.py validate "$RUNNER_TEMP/signed"', validation)

    def test_promotion_reads_before_minting_repository_scoped_tokens(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/release-publication.yml").read_text()
        self.assertLess(workflow.index("prepare-promotion"), workflow.index("Mint publication token"))
        for repository in ("glimmer", "homebrew-glimmer"):
            self.assertIn(f"repositories: {repository}\n", workflow)
        self.assertEqual(workflow.count("permission-contents: write"), 3)
        self.assertEqual(workflow.count("permission-workflows: write"), 1)
        for forbidden in ("permission-actions:", "skip-token-revoke:",
                          "SPARKLE_ED_PRIVATE_KEY", "DEVELOPER_ID_P12_BASE64"):
            self.assertNotIn(forbidden, workflow)
        for job in self.jobs("release-publication.yml", ("publish", "tap")):
            publication = job.split("- name: Select publication credentials", 1)[1]
            self.assertNotIn("permission-workflows:", publication)
            self.assertNotIn("GLIMMER_RC_APP", publication)

    def test_final_tag_uses_candidate_app_identity_after_verification_before_publication(self):
        job, = self.jobs("release-publication.yml", ("publish",))
        checkout = job.index('git checkout --detach "$TOOLING_SHA"')
        prepare = job.index("run: scripts/ci-release.sh prepare-promotion")
        mint = job.index("- name: Mint a scoped release tag token")
        tag = job.index("- name: Create final version tag at the verified candidate")
        credentials = job.index("- name: Select publication credentials")
        publish = job.index("- name: Publish candidate or promote accepted bytes")
        self.assertLess(checkout, prepare)
        self.assertLess(prepare, mint)
        self.assertLess(mint, tag)
        self.assertLess(tag, credentials)
        self.assertLess(credentials, publish)
        step = job[mint:credentials]
        self.assertEqual(step.count("if: inputs.operation == 'promote'"), 2)
        for required in ("secrets.GLIMMER_RC_APP_CLIENT_ID", "secrets.GLIMMER_RC_APP_PRIVATE_KEY",
                         "owner: Se7enbrc\n", "repositories: glimmer\n", "permission-contents: write",
                         "permission-workflows: write", "GH_TOKEN: ${{ steps.tag-app.outputs.token }}",
                         "gh auth setup-git", 'git config user.name "${APP_SLUG}[bot]"',
                         'git config user.email "${APP_SLUG}[bot]@users.noreply.github.com"',
                         'python3 scripts/promote-release.py tag "$RC_TAG" "$CANDIDATE_SHA"'):
            self.assertIn(required, step)
        self.assertNotIn("continue-on-error:", job)
        self.assertNotIn("always()", job[:publish])
        self.assertIn("CANDIDATE_SHA: ${{ inputs.candidate_sha }}", job)
        self.assertIn("RC_TAG: ${{ inputs.rc_tag }}", job)
        tap, = self.jobs("release-publication.yml", ("tap",))
        self.assertNotIn("GLIMMER_RC_APP", tap)
        self.assertNotIn("promote-release.py tag", tap)

    def test_promotion_validates_with_a_token_before_publishing_credentials(self):
        job, = self.jobs("release-publication.yml", ("publish",))
        step = job.split("- name: Publish candidate or promote accepted bytes", 1)[1].split("- name:", 1)[0]
        self.assertIn("GH_TOKEN: ${{ github.token }}", step)
        self.assertIn("RELEASE_CONTENTS_TOKEN:", step)
        self.assertIn("steps.publication-token.outputs.token", step)
        self.assertNotIn("steps.tag-app.outputs.token", step)
        self.assertIn("promote) scripts/ci-release.sh promote ;;", step)

    def test_hosted_signing_targets_cannot_reach_compilation_or_launch_probes(self):
        makefile = (Path(__file__).resolve().parents[1] / "release-bundle.mk").read_text()
        sign = makefile.split("\nsign-bundle:", 1)[1].split("\n\n", 1)[0]
        notarize = makefile.split("\nnotarize-bundle:", 1)[1].split("\n\n", 1)[0]
        dmg = makefile.split("\nnotarize-dmg:", 1)[1].split("\n\n", 1)[0]
        self.assertTrue(sign.startswith(" signing-preflight ensure-signing\n"))
        self.assertTrue(notarize.startswith(" sign-bundle appcast-feed\n"))
        for forbidden in ("xcodebuild", "swiftc", "embed-helper", "--validate-distribution"):
            self.assertNotIn(forbidden, sign + notarize + dmg)

    def jobs(self, workflow, names):
        source = (Path(__file__).resolve().parents[2] / ".github/workflows" / workflow).read_text()
        return [re.split(r"\n  [a-z][a-z-]*:\n", source.split(f"\n  {name}:\n", 1)[1])[0]
                for name in names]

    def shell(self, job, name):
        step = job.split(f"- name: {name}\n", 1)[1].split("\n      - name:", 1)[0]
        return textwrap.dedent(step.split("        run: |\n", 1)[1])

    def test_tooling_checkout_proves_ancestry_before_detaching_at_the_pin(self):
        jobs = self.jobs("release.yml", ("sign", "validate"))
        jobs += self.jobs("release-publication.yml", ("publish", "tap"))
        for job in jobs:
            self.assertIn("ref: main\n", job)
            self.assertIn("fetch-depth: 0", job)
            self.assertNotIn("ref: ${{", job)
            shell = self.shell(job, "Check out the pinned main tooling")
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                log = root / "calls"
                git = root / "git"
                git.write_text(f"#!{sys.executable}\n" +
                               'import os, pathlib, sys\n'
                               'with pathlib.Path(os.environ["CALLS"]).open("a") as log:\n'
                               '    log.write(" ".join(sys.argv[1:]) + "\\n")\n'
                               'if sys.argv[1] == "merge-base":\n'
                               '    sys.exit(int(os.environ["ANCESTRY_RESULT"]))\n')
                git.chmod(0o755)
                for sha, status, succeeds in (("a" * 40, "0", True), ("b" * 40, "1", False),
                                              ("c" * 40, "128", False), ("main", "0", False),
                                              ("", "0", False)):
                    with self.subTest(sha=sha, ancestry=status):
                        log.write_text("")
                        result = subprocess.run(["/bin/bash", "-euo", "pipefail", "-c", shell],
                                                env={"PATH": temporary, "CALLS": str(log), "TOOLING_SHA": sha,
                                                     "ANCESTRY_RESULT": status}, capture_output=True, text=True)
                        self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                        calls = log.read_text().splitlines()
                        if succeeds:
                            self.assertEqual(calls, [f"merge-base --is-ancestor {sha} origin/main",
                                                     f"checkout --detach {sha}"])
                        else:
                            self.assertFalse(any(call.startswith("checkout") for call in calls))

    def test_publication_credentials_require_a_complete_pair_or_explicit_pat_fallback(self):
        jobs = self.jobs("release-publication.yml", ("publish", "tap"))
        for token, job in zip(("publication-token", "tap-token"), jobs):
            self.assertIn("client-id: ${{ secrets.GLIMMER_RELEASE_APP_CLIENT_ID }}", job)
            self.assertIn("private-key: ${{ secrets.GLIMMER_RELEASE_APP_PRIVATE_KEY }}", job)
            self.assertNotIn("app-id:", job)
            self.assertNotIn("vars.GLIMMER_RELEASE", job)
            self.assertIn("if: steps.credentials.outputs.mode == 'app'", job)
            selection = job.split("          RELEASE_CONTENTS_TOKEN:\n", 1)[1].split("        run:", 1)[0]
            self.assertEqual(" ".join(selection.split()),
                             "${{ steps.credentials.outputs.mode == 'pat' && secrets.RELEASE_CONTENTS_TOKEN || "
                             f"steps.{token}.outputs.token " + "}}")
            self.assertLess(job.index("Select publication credentials"),
                            job.index(f"id: {token}\n"))
            shell = self.shell(job, "Select publication credentials")
            for client, key, mode in (("fixture-client", "fixture-key", "app"), ("", "", "pat"),
                                      ("fixture-client", "", None), ("", "fixture-key", None)):
                with self.subTest(client=bool(client), key=bool(key)), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    output, summary = root / "output", root / "summary"
                    output.touch()
                    summary.touch()
                    result = subprocess.run(["/bin/bash", "-euo", "pipefail", "-c", shell],
                                            env={"RELEASE_APP_CLIENT_ID": client, "RELEASE_APP_PRIVATE_KEY": key,
                                                 "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary)},
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, mode is not None, result.stderr)
                    self.assertEqual(output.read_text(), f"mode={mode}\n" if mode else "")
                    if mode == "pat":
                        self.assertIn("PAT fallback", summary.read_text())
                        self.assertIn("both App secrets are absent", summary.read_text())
                    if mode is None:
                        self.assertIn("Configure both", result.stderr)
                    self.assertNotIn("fixture-key", result.stdout + result.stderr + summary.read_text())
