# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Hosted release boundaries with disposable files and inert git/signing tools."""

import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from fixture_git import FixtureTestCase

from fixture_process import run_fixture

SCRIPT = Path(__file__).resolve().parents[1] / "ci-release.sh"
SHA = "a" * 40
TOOL = r'''
import json, os, pathlib, plistlib, stat, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
record = {"tool": name, "args": args}
if name == "hk":
    record["scan_all_files"] = os.environ.get("GLIMMER_SECRET_SCAN_ALL_FILES")
private = pathlib.Path(os.environ["RUNNER_TEMP"]) / "glimmer-release-12-1"
app = pathlib.Path("build/Build/Products/Release/Glimmer.app/Contents")
if name == "rm":
    if os.environ.get("FIXTURE_FAIL_REMOVE") and args == ["-rf", str(private)]:
        sys.exit(8)
    sys.exit(subprocess.run(["/bin/rm", *args]).returncode)
elif name == "git":
    if args == ["rev-parse", "HEAD"]:
        print(os.environ.get("FIXTURE_HEAD", "a" * 40))
    elif args == ["rev-parse", "FETCH_HEAD^{commit}"]:
        print(os.environ.get("FIXTURE_TAG_SHA", "a" * 40))
    elif args == ["rev-parse", "origin/main"]:
        print(os.environ.get("FIXTURE_MAIN", "a" * 40))
    elif args == ["rev-parse", "origin/release-candidate"]:
        print(os.environ.get("FIXTURE_SOURCE", "a" * 40))
    elif args[:1] == ["show"]:
        print("MARKETING_VERSION = 2026.10.6\nCURRENT_PROJECT_VERSION = 400")
    elif args == ["remote", "get-url", "origin"]:
        print(os.environ.get("FIXTURE_ORIGIN", "https://github.com/Se7enbrc/glimmer"))
    elif args[:1] == ["clone"]:
        pathlib.Path(args[-1]).mkdir()
elif name == "make" and args == ["-f", "scripts/ci-signing.mk", "codesign-setup", "setup-notary"]:
    (private / "signing.keychain-db").touch()
    record["modes"] = {p.name: stat.S_IMODE(p.stat().st_mode) for p in private.iterdir()}
    record["secret_env_removed"] = "P12_PASSWORD" not in os.environ
elif name == "make" and args == ["CONFIG=Release", "embed-helper"]:
    for relative in ("MacOS/Glimmer", "Info.plist",
                     "Library/LaunchServices/Glimmer Network Helper.app/Contents/MacOS/io.ugfugl.glimmer.helper",
                     "Library/LaunchServices/Glimmer Network Helper.app/Contents/Info.plist"):
        path = app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("inert unsigned fixture")
        path.chmod(0o755)
    record["private_exists"] = private.exists()
    record["secret_env_present"] = "P12_PASSWORD" in os.environ
    config = pathlib.Path(os.environ['XCODE_XCCONFIG_FILE']).read_text()
    diagnostic = config.rstrip().endswith('GLIMMER_DIAGNOSTIC_BUILD = YES')
    (app / 'Info.plist').write_bytes(plistlib.dumps({'GlimmerDiagnosticBuild': diagnostic}))
    record['diagnostic'] = diagnostic
elif name == "make" and args == ["-f", "scripts/ci-signing.mk", "CONFIG=Release", "dmg"]:
    path = pathlib.Path("build/dist/Glimmer-2026.10.6.dmg")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("inert unsigned dmg fixture")
elif name == "make" and args == ["-f", "scripts/ci-signing.mk", "CONFIG=Release", "notarize-dmg"]:
    pathlib.Path("build/dist/Glimmer-2026.10.6.dmg").write_text("inert signed and stapled dmg fixture")
    record["signing_available"] = (private / "signing.keychain-db").exists()
elif name == "make" and args == ["-f", "scripts/ci-signing.mk", "CONFIG=Release", "sparkle-zip"]:
    path = pathlib.Path("build/dist/Glimmer-2026.10.6.zip")
    path.write_text("inert zip distribution fixture")
    record["private_exists"] = private.exists()
    record["secret_env_present"] = "P12_PASSWORD" in os.environ or "RELEASE_CONTENTS_TOKEN" in os.environ
elif name == "gh":
    print(os.environ.get("FIXTURE_STABLE", "false"))
elif name == "promote-release.py":
    promotion = pathlib.Path(os.environ["RUNNER_TEMP"]) / "glimmer-promotion-12-1"
    if args[0] == "prepare":
        promotion.mkdir(exist_ok=True)
        (promotion / "Glimmer-2026.10.6.dmg").write_text("verified fixture")
    elif not promotion.exists():
        sys.exit(1)
elif name == "release_publication.py" and args[0] == "check":
    if not (pathlib.Path(args[1]) / "manifest.json").exists():
        sys.exit(1)
elif name == "release_publication.py" and args[0] == "publish":
    helper = pathlib.Path(os.environ["GIT_CONFIG_VALUE_1"])
    record["helper_contains_token"] = os.environ["RELEASE_CONTENTS_TOKEN"] in helper.read_text()
    record["credential_mode"] = stat.S_IMODE(private.stat().st_mode)
    for host in ("github.com", "untrusted.example"):
        result = subprocess.run([str(helper), "get"], input=f"protocol=https\nhost={host}\n\n",
                                capture_output=True, text=True, check=True)
        record[host] = "password=" in result.stdout
with open(os.environ["FIXTURE_LOG"], "a") as log:
    log.write(json.dumps(record) + "\n")
if os.environ.get("FIXTURE_FAIL") == name + ":" + " ".join(args):
    sys.exit(1)
if name == "release_publication.py" and args[0] == "publish" and os.environ.get("FIXTURE_FAIL_PUBLISH"):
    sys.exit(1)
if name == "security" and os.environ.get("FIXTURE_FAIL_DELETE"):
    sys.exit(9)
'''


class HostedReleaseTests(FixtureTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="glimmer ci fixture ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "Glimmer").mkdir()
        (self.root / "Glimmer/Version.xcconfig").write_text(
            "MARKETING_VERSION = 2026.10.6\nCURRENT_PROJECT_VERSION = 400\n")
        shutil.copy2(SCRIPT, self.root / "scripts/ci-release.sh")
        shutil.copy2(SCRIPT.parent / 'release_candidate_kind.py', self.root / 'scripts')
        shutil.copy2(SCRIPT.parent / 'release_symbols.py', self.root / 'scripts')
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.runner = self.root / "runner"
        self.runner.mkdir()
        (self.runner / "attestation.jsonl").write_text('{"fixture": "bundle"}\n')
        self.private = self.runner / "glimmer-release-12-1"
        self.log = self.root / "calls.jsonl"
        for name in ("make", "git", "security", "rm", "hk", "publish-release.sh", "homebrew-bump.sh",
                     "release-checks.py", "promote-release.py", "release_publication.py", "gh"):
            path = (self.root / "scripts" if name.endswith((".sh", ".py")) else self.bin) / name
            path.write_text(f"#!{sys.executable}\n" + TOOL)
            path.chmod(0o755)
        (self.bin / "python3").symlink_to(sys.executable)
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.root),
            "RUNNER_TEMP": str(self.runner), "GITHUB_RUN_ID": "12", "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REPOSITORY": "Se7enbrc/glimmer", "GITHUB_REF": "refs/heads/release-candidate",
            "RELEASE_OPERATION": "candidate", "RC_TAG": "2026.10.6-rc.1", "CANDIDATE_SHA": "b" * 40,
            "GITHUB_SHA": SHA, "EXPECTED_SHA": SHA, "FIXTURE_LOG": str(self.log),
            "GITHUB_OUTPUT": str(self.runner / "workflow-output"), "RELEASE_ATTESTATION_ID": "123",
            "RELEASE_PROVENANCE_BUNDLE": str(self.runner / "attestation.jsonl"),
            "P12_PASSWORD": "fixture-password", "NOTARY_KEY_ID": "fixture-key-id",
            "NOTARY_ISSUER_ID": "fixture-issuer", "SPARKLE_ED_PRIVATE_KEY": "fixture-sparkle",
            "RELEASE_CONTENTS_TOKEN": "fixture-token-private",
        }
        for key in ("DEVELOPER_ID_P12_BASE64", "NOTARY_KEY_BASE64",
                    "APP_PROVISIONPROFILE_BASE64", "HELPER_PROVISIONPROFILE_BASE64"):
            self.env[key] = base64.b64encode(b"inert fixture").decode()
    def run_phase(self, phase):
        environment = dict(self.env)
        signing = {"DEVELOPER_ID_P12_BASE64", "P12_PASSWORD", "NOTARY_KEY_BASE64", "NOTARY_KEY_ID",
                   "NOTARY_ISSUER_ID", "APP_PROVISIONPROFILE_BASE64", "HELPER_PROVISIONPROFILE_BASE64"}
        allowed = {"sign": signing, "publish": {"SPARKLE_ED_PRIVATE_KEY", "RELEASE_CONTENTS_TOKEN"},
                   "promote": {"RELEASE_CONTENTS_TOKEN"}, "tap": {"RELEASE_CONTENTS_TOKEN"}}.get(phase, set())
        for key in signing | {"SPARKLE_ED_PRIVATE_KEY", "RELEASE_CONTENTS_TOKEN"}:
            if key not in allowed:
                environment.pop(key, None)
        return run_fixture(["/bin/bash", "scripts/ci-release.sh", phase], cwd=self.root, env=environment)
    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
    def verified(self):
        self.assertEqual(self.run_phase("checks").returncode, 0)
        self.assertEqual([call["args"] for call in self.calls() if call["tool"] == "release-checks.py"][-1],
                         [SHA, "--candidate", "--delivery"])
        for part in ("checks", "tests", "asan"):
            output = Path(self.env["GITHUB_OUTPUT"])
            output.write_text("")
            result = self.run_phase(f"verify-{part}")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.env[f"VERIFY_{part.upper()}_RESULT"] = "success"
            self.env[f"VERIFY_{part.upper()}_RECORD"] = output.read_text().removeprefix("record=").strip()
        output.write_text("")
        result = self.run_phase("verified")
        self.assertEqual(result.returncode, 0, result.stderr)
    def verification_args(self, part):
        target = {"checks": "check-portable", "tests": "test", "asan": "test-asan"}[part]
        return [target, f"DERIVED={self.root.resolve()}/build", "TEST_SUITE="] + (["COVERAGE=1"] if part == "tests" else [])
    def built(self):
        self.verified()
        result = self.run_phase("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.env["TRUSTED_TOOLING_SHA"] = SHA
    def signed_artifact(self):
        path = self.runner / "signed"
        path.mkdir(exist_ok=True)
        (path / "manifest.json").write_text("inert fixture, verified by the artifact tests")
    def packaged(self):
        self.built()
        for phase in ("sign", "package"):
            result = self.run_phase(phase)
            self.assertEqual(result.returncode, 0, result.stderr)
    def transfer_unsigned(self):
        self.built()
        shutil.copy2(SCRIPT.parent / "release_artifact.py", self.root / "scripts/release_artifact.py")
        output = Path(self.env["GITHUB_OUTPUT"])
        output.write_text("")
        result = subprocess.run([sys.executable, "scripts/release_artifact.py", "unsigned",
                                 str(self.runner / "unsigned"), "--app",
                                 "build/Build/Products/Release/Glimmer.app"],
                                cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        values = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.env.update(UNSIGNED_MANIFEST=values["manifest"], UNSIGNED_ATTEMPT=values["attempt"])
        shutil.rmtree(self.root / "build/Build/Products/Release")
        for suffix in ("", "-built"):
            (self.runner / f"glimmer-verified-12-1{suffix}").unlink()
    def test_fresh_signer_requires_verified_handoff_before_credentials(self):
        self.transfer_unsigned()
        self.assertNotEqual(self.run_phase("sign").returncode, 0)
        result = self.run_phase("import-unsigned")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_phase("sign").returncode, 0)
        args = [call["args"] for call in self.calls() if call["tool"] == "make"]
        self.assertEqual(args.count(["CONFIG=Release", "embed-helper"]), 1)
        self.assertIn(["-f", "scripts/ci-signing.mk", "CONFIG=Release", "signing-preflight", "notarize-bundle"], args)
    def test_tampered_handoff_cannot_create_signing_authorization(self):
        self.transfer_unsigned()
        (self.runner / "unsigned/Glimmer.app.tar.gz").write_bytes(b"tampered")
        self.assertNotEqual(self.run_phase("import-unsigned").returncode, 0)
        self.assertNotEqual(self.run_phase("sign").returncode, 0)
        self.assertFalse(self.private.exists())
        self.assertFalse(any(call["tool"] == "security" for call in self.calls()))
    def test_untrusted_contexts_stop_before_build_or_credentials(self):
        for key, value in (("GITHUB_REF", "refs/heads/feature"), ("GITHUB_REPOSITORY", "fork/glimmer"),
                           ("GITHUB_EVENT_NAME", "pull_request"), ("GITHUB_SHA", "b" * 40),
                           ("EXPECTED_SHA", "main;anything"), ("RUNNER_DEBUG", "1"),
                           ("ACTIONS_STEP_DEBUG", "true"), ("ACTIONS_STEP_DEBUG", "TRUE"),
                           ("ACTIONS_RUNNER_DEBUG", "true"), ("ACTIONS_RUNNER_DEBUG", "TRUE"),
                           ("FIXTURE_SOURCE", "b" * 40),
                           ("FIXTURE_TAG_SHA", "b" * 40), ("RC_TAG", "2026.10.5-rc.1"),
                           ("RELEASE_OPERATION", "stable"),
                           ("FIXTURE_ORIGIN", "https://untrusted.example/glimmer")):
            with self.subTest(key=key):
                previous = self.env.get(key)
                self.env[key] = value
                self.assertNotEqual(self.run_phase("sign").returncode, 0)
                self.assertFalse(self.private.exists())
                if previous is None:
                    self.env.pop(key)
                else:
                    self.env[key] = previous
        self.assertFalse(any(call["tool"] in ("make", "security") for call in self.calls()))
    def test_diagnostic_build_marker_comes_from_tag_and_promotion_is_rejected(self):
        self.env['RC_TAG'] += '-diag'
        self.verified()
        result = self.run_phase('build')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(next(call['diagnostic'] for call in self.calls() if 'diagnostic' in call))
        self.env.update(RELEASE_OPERATION='promote', GITHUB_REF='refs/heads/main')
        result = self.run_phase('check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('diagnostic candidates cannot be promoted', result.stderr)
    def test_failed_verify_cannot_authorize_signing(self):
        self.assertEqual(self.run_phase("checks").returncode, 0)
        self.env["FIXTURE_FAIL"] = "make:" + " ".join(self.verification_args("checks"))
        self.assertNotEqual(self.run_phase("verify-checks").returncode, 0)
        self.env.pop("FIXTURE_FAIL")
        self.assertNotEqual(self.run_phase("sign").returncode, 0)
        self.assertFalse(self.private.exists())
    def test_native_checks_must_finish_before_the_test_record(self):
        self.assertEqual(self.run_phase("checks").returncode, 0)
        output = Path(self.env["GITHUB_OUTPUT"])
        output.write_text("")
        self.env["FIXTURE_FAIL"] = "make:check-macos"
        self.assertNotEqual(self.run_phase("verify-tests").returncode, 0)
        self.assertNotIn("record=", output.read_text())
    def test_each_verification_part_must_finish_before_emitting_a_record(self):
        self.assertEqual(self.run_phase("checks").returncode, 0)
        output = Path(self.env["GITHUB_OUTPUT"])
        for part in ("checks", "tests", "asan"):
            with self.subTest(part=part):
                output.write_text("")
                self.env["FIXTURE_FAIL"] = "make:" + " ".join(self.verification_args(part))
                self.assertNotEqual(self.run_phase(f"verify-{part}").returncode, 0)
                self.assertEqual(output.read_text(), "")
                self.env.pop("FIXTURE_FAIL")
                self.assertNotEqual(self.run_phase("verified").returncode, 0)
                self.assertNotEqual(self.run_phase("build").returncode, 0)
                self.assertNotEqual(self.run_phase("sign").returncode, 0)
                self.assertFalse(self.private.exists())
    def test_unsuccessful_or_mismatched_job_records_cannot_authorize_build_or_sign(self):
        self.verified()
        for part in ("checks", "tests", "asan"):
            result_key = f"VERIFY_{part.upper()}_RESULT"
            record_key = f"VERIFY_{part.upper()}_RECORD"
            changes = [(result_key, state) for state in ("failure", "cancelled", "skipped", "", "pending")]
            changes += [(record_key, record) for record in
                        ("", f"{'b' * 40} 12 1 {part}", f"{SHA} 13 1 {part}",
                         f"{SHA} 12 2 {part}", f"{SHA} 12 1 other", f"{SHA} 12 0 {part}",
                         f"{SHA} 12 -1 {part}", f"{SHA} 12 nope {part}", f"{SHA} 12 1 {part} extra",
                         f"{SHA} 12 1 {part}\nextra")]
            for key, value in changes:
                with self.subTest(part=part, key=key, value=value):
                    previous = self.env[key]
                    self.env[key] = value
                    self.assertNotEqual(self.run_phase("verified").returncode, 0)
                    self.assertNotEqual(self.run_phase("build").returncode, 0)
                    self.assertNotEqual(self.run_phase("sign").returncode, 0)
                    self.assertFalse(self.private.exists())
                    self.env[key] = previous
        self.assertFalse(any(call["tool"] == "security" for call in self.calls()))
    def test_verification_records_identify_each_isolated_job_and_report_duration(self):
        self.env["GITHUB_STEP_SUMMARY"] = str(self.runner / "summary")
        self.verified()
        for part in ("checks", "tests", "asan"):
            self.assertEqual(self.env[f"VERIFY_{part.upper()}_RECORD"], f"{SHA} 12 1 {part}")
            self.assertIn(self.verification_args(part), [call["args"] for call in self.calls()])
            self.assertIn(f"Verification {part}: {SHA}, run 12, attempt 1,",
                          Path(self.env["GITHUB_STEP_SUMMARY"]).read_text())
    def test_checks_and_precreated_tag_are_required_before_any_compilation(self):
        self.assertNotEqual(self.run_phase("verify-checks").returncode, 0)
        self.assertFalse(any(call["tool"] == "security" or
                             (call["tool"] == "make" and "guard-clean-tree" not in call["args"])
                             for call in self.calls()))
        self.env["FIXTURE_FAIL"] = "git:fetch --quiet origin refs/tags/2026.10.6-rc.1"
        self.assertNotEqual(self.run_phase("checks").returncode, 0)
        self.assertFalse(any(call["tool"] == "release-checks.py" for call in self.calls()))
        self.env["FIXTURE_FAIL"] = "release-checks.py:" + SHA + " --candidate --delivery"
        self.assertNotEqual(self.run_phase("checks").returncode, 0)
        self.assertNotEqual(self.run_phase("verify-checks").returncode, 0)
        self.assertFalse(any(call["tool"] == "security" or
                             (call["tool"] == "make" and "guard-clean-tree" not in call["args"])
                             for call in self.calls()))
    def test_promotion_never_builds_or_signs_and_tap_requires_successful_promotion(self):
        self.env.update(RELEASE_OPERATION="promote", GITHUB_REF="refs/heads/main")
        for phase in ("verify-checks", "verify-tests", "verify-asan", "verified",
                      "build", "sign", "package", "publish", "tap"):
            with self.subTest(phase=phase):
                self.assertNotEqual(self.run_phase(phase).returncode, 0)
        self.assertFalse(any(call["tool"] == "security" or
                             (call["tool"] == "make" and "guard-clean-tree" not in call["args"])
                             for call in self.calls()))
        self.assertEqual(self.run_phase("checks").returncode, 0)
        for phase in ("prepare-promotion", "promote", "tap", "cleanup"):
            if phase == "tap":
                self.env["FIXTURE_STABLE"] = "true"
            result = self.run_phase(phase)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(self.private.exists())
        clone = next(call for call in self.calls() if call["tool"] == "git" and call["args"][0] == "clone")
        self.assertEqual(clone["args"][2], "https://github.com/Se7enbrc/homebrew-glimmer.git")
        tap = next(call for call in self.calls() if call["tool"] == "homebrew-bump.sh")
        self.assertEqual(tap["args"], ["2026.10.6", "2026.10.6-rc.1"])
    def test_promotion_checks_main_and_candidate_before_authorizing_any_phase(self):
        self.env.update(RELEASE_OPERATION="promote", GITHUB_REF="refs/heads/main")
        self.assertEqual(self.run_phase("checks").returncode, 0)
        checks = [call["args"] for call in self.calls() if call["tool"] == "release-checks.py"]
        self.assertEqual(checks, [[SHA], ["b" * 40, "--candidate", "--delivery"]])
        self.env["FIXTURE_FAIL"] = "release-checks.py:" + "b" * 40 + " --candidate --delivery"
        self.assertNotEqual(self.run_phase("checks").returncode, 0)
        self.assertNotEqual(self.run_phase("prepare-promotion").returncode, 0)
        self.assertFalse(any(call["tool"] == "promote-release.py" for call in self.calls()))
    def test_failed_precommit_stops_before_verify_and_cannot_authorize_build(self):
        self.assertEqual(self.run_phase("checks").returncode, 0)
        self.env["FIXTURE_FAIL"] = "hk:check --all"
        self.assertNotEqual(self.run_phase("verify-checks").returncode, 0)
        self.env.pop("FIXTURE_FAIL")
        self.assertNotEqual(self.run_phase("build").returncode, 0)
        calls = self.calls()
        hook = next(call for call in calls if call["tool"] == "hk")
        self.assertEqual(hook["scan_all_files"], "1")
        self.assertFalse(any(call["tool"] == "make" and call["args"] == self.verification_args("checks")
                             for call in calls))
        self.assertFalse(self.private.exists())
    def test_signing_failure_reaps_temporary_keychain_and_files(self):
        self.built()
        self.env["FIXTURE_FAIL"] = "make:-f scripts/ci-signing.mk CONFIG=Release signing-preflight notarize-bundle"
        result = self.run_phase("sign")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.private.exists())
        setup = next(call for call in self.calls() if call["args"] == ["-f", "scripts/ci-signing.mk", "codesign-setup", "setup-notary"])
        self.assertTrue(setup["secret_env_removed"])
        self.assertTrue(all(mode == 0o600 for mode in setup["modes"].values()))
        self.assertTrue(any(call["tool"] == "security" and call["args"][0] == "delete-keychain"
                            for call in self.calls()))
        self.assertNotIn("fixture-password", result.stdout + result.stderr)
    def test_moved_candidate_after_verify_cannot_sign(self):
        self.built()
        self.env["FIXTURE_SOURCE"] = "b" * 40
        self.assertNotEqual(self.run_phase("sign").returncode, 0)
        self.assertFalse(self.private.exists())
    def test_publication_token_is_not_written_and_helper_restricts_host(self):
        self.signed_artifact()
        self.env["FIXTURE_FAIL_PUBLISH"] = "1"
        result = self.run_phase("publish")
        self.assertNotEqual(result.returncode, 0)
        publication = next(call for call in self.calls()
                           if call["tool"] == "release_publication.py" and call["args"][0] == "publish")
        self.assertFalse(publication["helper_contains_token"])
        self.assertTrue(publication["github.com"])
        self.assertFalse(publication["untrusted.example"])
        self.assertEqual(publication["credential_mode"], 0o700)
        self.assertFalse(self.private.exists())
        self.assertNotIn(self.env["RELEASE_CONTENTS_TOKEN"], result.stdout + result.stderr)
    def test_invalid_material_fails_before_keychain_setup(self):
        self.built()
        self.env["DEVELOPER_ID_P12_BASE64"] = "invalid base64"
        self.assertNotEqual(self.run_phase("sign").returncode, 0)
        self.assertFalse(self.private.exists())
        self.assertFalse(any(call["args"] == ["-f", "scripts/ci-signing.mk", "codesign-setup", "setup-notary"] for call in self.calls()))
    def test_complete_sequence_cleans_each_phase_and_clones_tap_over_https(self):
        self.verified()
        calls = self.calls()
        hook_index = next(index for index, call in enumerate(calls) if call["tool"] == "hk")
        verify_index = next(index for index, call in enumerate(calls)
                            if call["tool"] == "make" and call["args"] == self.verification_args("checks"))
        self.assertLess(hook_index, verify_index)
        self.signed_artifact()
        self.env["TRUSTED_TOOLING_SHA"] = SHA
        for phase in ("build", "sign", "package", "publish", "cleanup"):
            with self.subTest(phase=phase):
                result = self.run_phase(phase)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(self.private.exists())
        self.assertNotEqual(self.run_phase("tap").returncode, 0)
        self.assertFalse(any(call["tool"] == "homebrew-bump.sh" for call in self.calls()))
        for call in self.calls():
            if call["tool"] == "make" and "private_exists" in call:
                self.assertFalse(call["private_exists"])
                self.assertFalse(call["secret_env_present"])
        make_args = [call["args"] for call in self.calls() if call["tool"] == "make"]
        self.assertIn(["-f", "scripts/ci-signing.mk", "CONFIG=Release", "signing-preflight", "notarize-bundle"], make_args)
        self.assertFalse(any("dist" in args for args in make_args))
    def test_tooling_outside_main_history_cannot_publish(self):
        self.packaged()
        self.env["FIXTURE_FAIL"] = f"git:merge-base --is-ancestor {SHA} origin/main"
        self.assertNotEqual(self.run_phase("publish").returncode, 0)
        self.assertFalse(self.private.exists())
        self.assertFalse(any(call["tool"] == "release_publication.py" and call["args"][0] == "publish"
                             for call in self.calls()))
    def test_packaging_outputs_only_the_two_final_assets_and_records_their_bytes(self):
        self.packaged()
        paths = [self.root.resolve() / f"build/dist/Glimmer-2026.10.6.{suffix}" for suffix in ("dmg", "zip")]
        output = Path(self.env["GITHUB_OUTPUT"]).read_text()
        self.assertEqual(output, f"dmg-path={paths[0]}\nzip-path={paths[1]}\n")
        digests = (self.runner / "glimmer-verified-12-1-packaged-artifacts").read_text()
        self.assertEqual(len(digests.splitlines()), 2)
        for path in paths:
            self.assertIn(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path}\n", digests)
    def test_package_preserves_stapled_dmg_and_retry_never_rebuilds_it(self):
        self.env['GITHUB_STEP_SUMMARY'] = str(self.runner / 'summary')
        self.packaged()
        dmg = self.root / 'build/dist/Glimmer-2026.10.6.dmg'
        self.assertEqual(dmg.read_text(), 'inert signed and stapled dmg fixture')
        self.assertEqual(self.run_phase('package').returncode, 0)
        self.assertEqual(dmg.read_text(), 'inert signed and stapled dmg fixture')
        calls = self.calls()
        args = [call['args'] for call in calls if call['tool'] == 'make']
        self.assertEqual(args.count(['-f', 'scripts/ci-signing.mk', 'CONFIG=Release', 'dmg']), 1)
        self.assertEqual(args.count(['-f', 'scripts/ci-signing.mk', 'CONFIG=Release', 'notarize-dmg']), 1)
        self.assertLess(args.index(['-f', 'scripts/ci-signing.mk', 'CONFIG=Release', 'signing-preflight', 'notarize-bundle']),
                        args.index(['-f', 'scripts/ci-signing.mk', 'CONFIG=Release', 'dmg']))
        self.assertLess(args.index(['-f', 'scripts/ci-signing.mk', 'CONFIG=Release', 'dmg']), args.index(['-f', 'scripts/ci-signing.mk', 'CONFIG=Release', 'notarize-dmg']))
        signed = next(index for index, call in enumerate(calls) if call.get('signing_available'))
        cleanup = next(index for index, call in enumerate(calls) if call['tool'] == 'security')
        packaged = next(index for index, call in enumerate(calls) if call['args'] == ['-f', 'scripts/ci-signing.mk', 'CONFIG=Release', 'sparkle-zip'])
        self.assertLess(signed, cleanup)
        self.assertLess(cleanup, packaged)
        self.assertIn('DMG packaging, signing, notarization and stapling:',
                      Path(self.env['GITHUB_STEP_SUMMARY']).read_text())
    def test_dmg_failure_cleans_credentials_and_cannot_authorize_package(self):
        self.built()
        for target in ('dmg', 'notarize-dmg'):
            with self.subTest(target=target):
                self.env['FIXTURE_FAIL'] = f'make:-f scripts/ci-signing.mk CONFIG=Release {target}'
                self.assertNotEqual(self.run_phase('sign').returncode, 0)
                self.assertFalse(self.private.exists())
                self.assertFalse((self.runner / 'glimmer-verified-12-1-signed').exists())
                self.assertNotEqual(self.run_phase('package').returncode, 0)



    def test_notary_key_mask_escapes_multiline_text_before_use(self):
        self.built()
        pem = "-----BEGIN INERT KEY-----\r\nfixture%0Avalue\n-----END INERT KEY-----\n"
        self.env["NOTARY_KEY_BASE64"] = base64.b64encode(pem.encode()).decode()
        result = self.run_phase("sign")
        self.assertEqual(result.returncode, 0, result.stderr)
        masks = [line for line in result.stdout.splitlines() if line.startswith("::add-mask::")]
        self.assertEqual(masks[0], "::add-mask::-----BEGIN INERT KEY-----%0D%0A"
                         "fixture%250Avalue%0A-----END INERT KEY-----%0A")
        self.assertEqual(len(masks), 2)
        self.assertNotIn(pem, result.stdout + result.stderr)
    def test_notary_key_invalid_utf8_rejected_without_printing_material(self):
        self.built()
        self.env["NOTARY_KEY_BASE64"] = base64.b64encode(b"inert-sensitive-fragment\xff").decode()
        result = self.run_phase("sign")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("notarization key is not UTF-8", result.stderr)
        self.assertNotIn("inert-sensitive-fragment", result.stdout + result.stderr)
        self.assertFalse(self.private.exists())
        self.assertFalse(any(call["args"] == ["-f", "scripts/ci-signing.mk", "codesign-setup", "setup-notary"] for call in self.calls()))
    def test_failed_unsigned_build_cannot_authorize_signing(self):
        self.verified()
        self.env["FIXTURE_FAIL"] = "make:CONFIG=Release embed-helper"
        self.assertNotEqual(self.run_phase("build").returncode, 0)
        self.env.pop("FIXTURE_FAIL")
        self.assertNotEqual(self.run_phase("sign").returncode, 0)
        self.assertFalse(self.private.exists())
    def test_missing_build_sign_and_package_proofs_fail_closed(self):
        self.verified()
        self.assertNotEqual(self.run_phase("sign").returncode, 0)
        self.built()
        self.assertNotEqual(self.run_phase("package").returncode, 0)
        self.assertNotEqual(self.run_phase("publish").returncode, 0)
        self.assertEqual(self.run_phase("sign").returncode, 0)
        self.assertNotEqual(self.run_phase("publish").returncode, 0)
    def test_missing_embedded_helper_stops_before_credentials(self):
        self.built()
        helper = self.root / "build/Build/Products/Release/Glimmer.app/Contents/Library/LaunchServices"
        shutil.rmtree(helper)
        self.assertNotEqual(self.run_phase("sign").returncode, 0)
        self.assertFalse(self.private.exists())
    def test_keychain_delete_failure_removes_files_but_cannot_authorize_package(self):
        self.built()
        self.env["FIXTURE_FAIL_DELETE"] = "1"
        result = self.run_phase("sign")
        self.assertEqual(result.returncode, 9)
        self.assertFalse(self.private.exists())
        self.assertFalse((self.runner / "glimmer-verified-12-1-signed").exists())
        self.assertNotEqual(self.run_phase("package").returncode, 0)
    def test_file_cleanup_failure_cannot_authorize_package(self):
        self.built()
        self.env["FIXTURE_FAIL_REMOVE"] = "1"
        result = self.run_phase("sign")
        self.assertEqual(result.returncode, 8)
        self.assertTrue(self.private.exists())
        self.assertFalse((self.runner / "glimmer-verified-12-1-signed").exists())
        self.assertNotEqual(self.run_phase("package").returncode, 0)
    def test_exit_cleanup_preserves_original_signing_error(self):
        self.built()
        self.env["FIXTURE_FAIL"] = "make:-f scripts/ci-signing.mk CONFIG=Release signing-preflight notarize-bundle"
        self.env["FIXTURE_FAIL_DELETE"] = "1"
        result = self.run_phase("sign")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.private.exists())
        self.assertFalse((self.runner / "glimmer-verified-12-1-signed").exists())
    def test_pinned_tooling_survives_main_advancing_before_publication(self):
        self.env.update(TRUSTED_TOOLING_SHA=SHA, FIXTURE_MAIN="b" * 40)
        self.signed_artifact()
        result = self.run_phase("publish")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["merge-base", "--is-ancestor", SHA, "origin/main"],
                      [call["args"] for call in self.calls()])
    def test_build_retry_accepts_successful_verification_from_earlier_attempts(self):
        self.verified()
        self.env["GITHUB_RUN_ATTEMPT"] = "3"
        self.env["VERIFY_TESTS_RECORD"] = f"{SHA} 12 2 tests"
        self.env["VERIFY_ASAN_RECORD"] = f"{SHA} 12 3 asan"
        self.assertEqual(self.run_phase("checks").returncode, 0)
        result = self.run_phase("verified")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.runner / "glimmer-verified-12-3").read_text().strip(), SHA)
        result = self.run_phase("build")
        self.assertEqual(result.returncode, 0, result.stderr)
    def test_missing_publication_token_stops_before_any_write(self):
        self.signed_artifact()
        self.env["RELEASE_CONTENTS_TOKEN"] = ""
        result = self.run_phase("publish")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing release contents token", result.stderr)
        self.assertFalse(any(call["tool"] == "release_publication.py" and call["args"][0] == "publish"
                             for call in self.calls()))
        self.assertFalse(self.private.exists())
