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

SCRIPT = Path(__file__).resolve().parents[1] / "ci-release.sh"
SHA = "a" * 40
TOOL = r'''
import json, os, pathlib, stat, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
record = {"tool": name, "args": args}
if name == "pre-commit":
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
    elif args in (["rev-parse", "origin/main"], ["rev-parse", "origin/release-candidate"]):
        print(os.environ.get("FIXTURE_MAIN", "a" * 40))
    elif args == ["remote", "get-url", "origin"]:
        print(os.environ.get("FIXTURE_ORIGIN", "https://github.com/Se7enbrc/glimmer"))
    elif args[:1] == ["clone"]:
        pathlib.Path(args[-1]).mkdir()
elif name == "make" and args == ["codesign-setup", "setup-notary"]:
    (private / "signing.keychain-db").touch()
    record["modes"] = {p.name: stat.S_IMODE(p.stat().st_mode) for p in private.iterdir()}
    record["secret_env_removed"] = "P12_PASSWORD" not in os.environ
elif name == "make" and args == ["CONFIG=Release", "guard-release-version", "clean", "app", "embed-helper"]:
    for relative in ("MacOS/Glimmer", "Info.plist",
                     "Library/LaunchServices/Glimmer Network Helper.app/Contents/MacOS/io.ugfugl.glimmer.helper",
                     "Library/LaunchServices/Glimmer Network Helper.app/Contents/Info.plist"):
        path = app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("inert unsigned fixture")
        path.chmod(0o755)
    record["private_exists"] = private.exists()
    record["secret_env_present"] = "P12_PASSWORD" in os.environ
elif name == "make" and args == ["CONFIG=Release", "dmg", "sparkle-zip"]:
    for suffix in ("dmg", "zip"):
        path = pathlib.Path(f"build/dist/Glimmer-2026.10.6.{suffix}")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"inert {suffix} distribution fixture")
    record["private_exists"] = private.exists()
    record["secret_env_present"] = "P12_PASSWORD" in os.environ or "RELEASE_CONTENTS_TOKEN" in os.environ
elif name == "publish-release.sh":
    helper = pathlib.Path(os.environ["GIT_CONFIG_VALUE_1"])
    record["helper_contains_token"] = os.environ["RELEASE_CONTENTS_TOKEN"] in helper.read_text()
    record["credential_mode"] = stat.S_IMODE((private / "signing.env").stat().st_mode)
    for host in ("github.com", "untrusted.example"):
        result = subprocess.run([str(helper), "get"], input=f"protocol=https\nhost={host}\n\n",
                                capture_output=True, text=True, check=True)
        record[host] = "password=" in result.stdout
with open(os.environ["FIXTURE_LOG"], "a") as log:
    log.write(json.dumps(record) + "\n")
if os.environ.get("FIXTURE_FAIL") == name + ":" + " ".join(args):
    sys.exit(1)
if name == "publish-release.sh" and os.environ.get("FIXTURE_FAIL_PUBLISH"):
    sys.exit(1)
if name == "security" and os.environ.get("FIXTURE_FAIL_DELETE"):
    sys.exit(9)
'''


class HostedReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="glimmer ci fixture ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "Glimmer").mkdir()
        (self.root / "Glimmer/Version.xcconfig").write_text(
            "MARKETING_VERSION = 2026.10.6\nCURRENT_PROJECT_VERSION = 400\n")
        shutil.copy2(SCRIPT, self.root / "scripts/ci-release.sh")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.runner = self.root / "runner"
        self.runner.mkdir()
        self.private = self.runner / "glimmer-release-12-1"
        self.log = self.root / "calls.jsonl"
        for name in ("make", "git", "security", "rm", "pre-commit", "publish-release.sh", "homebrew-bump.sh",
                     "release-checks.py", "promote-release.py"):
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
        return subprocess.run(["/bin/bash", "scripts/ci-release.sh", phase], cwd=self.root,
                              env=environment, capture_output=True, text=True, timeout=10)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def verified(self):
        self.assertEqual(self.run_phase("checks").returncode, 0)
        result = self.run_phase("verify")
        self.assertEqual(result.returncode, 0, result.stderr)

    def built(self):
        self.verified()
        result = self.run_phase("build")
        self.assertEqual(result.returncode, 0, result.stderr)

    def packaged(self):
        self.built()
        for phase in ("sign", "package"):
            result = self.run_phase(phase)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_untrusted_contexts_stop_before_build_or_credentials(self):
        for key, value in (("GITHUB_REF", "refs/heads/feature"), ("GITHUB_REPOSITORY", "fork/glimmer"),
                           ("GITHUB_EVENT_NAME", "pull_request"), ("GITHUB_SHA", "b" * 40),
                           ("EXPECTED_SHA", "main;anything"), ("RUNNER_DEBUG", "1"),
                           ("ACTIONS_STEP_DEBUG", "true"), ("ACTIONS_STEP_DEBUG", "TRUE"),
                           ("ACTIONS_RUNNER_DEBUG", "true"), ("ACTIONS_RUNNER_DEBUG", "TRUE"),
                           ("FIXTURE_MAIN", "b" * 40),
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

    def test_failed_verify_cannot_authorize_signing(self):
        self.assertEqual(self.run_phase("checks").returncode, 0)
        self.env["FIXTURE_FAIL"] = "make:verify"
        self.assertNotEqual(self.run_phase("verify").returncode, 0)
        self.env.pop("FIXTURE_FAIL")
        self.assertNotEqual(self.run_phase("sign").returncode, 0)
        self.assertFalse(self.private.exists())

    def test_checks_and_precreated_tag_are_required_before_any_compilation(self):
        self.assertNotEqual(self.run_phase("verify").returncode, 0)
        self.assertFalse(any(call["tool"] == "security" or
                             (call["tool"] == "make" and "guard-clean-tree" not in call["args"])
                             for call in self.calls()))
        self.env["FIXTURE_FAIL"] = "git:fetch --quiet origin refs/tags/2026.10.6-rc.1"
        self.assertNotEqual(self.run_phase("checks").returncode, 0)
        self.assertFalse(any(call["tool"] == "release-checks.py" for call in self.calls()))
        self.env["FIXTURE_FAIL"] = "release-checks.py:" + SHA
        self.assertNotEqual(self.run_phase("checks").returncode, 0)
        self.assertNotEqual(self.run_phase("verify").returncode, 0)
        self.assertFalse(any(call["tool"] == "security" or
                             (call["tool"] == "make" and "guard-clean-tree" not in call["args"])
                             for call in self.calls()))

    def test_promotion_never_builds_or_signs_and_tap_requires_successful_promotion(self):
        self.env.update(RELEASE_OPERATION="promote", GITHUB_REF="refs/heads/main")
        for phase in ("verify", "build", "sign", "package", "publish", "tap"):
            with self.subTest(phase=phase):
                self.assertNotEqual(self.run_phase(phase).returncode, 0)
        self.assertFalse(any(call["tool"] == "security" or
                             (call["tool"] == "make" and "guard-clean-tree" not in call["args"])
                             for call in self.calls()))
        self.assertEqual(self.run_phase("checks").returncode, 0)
        for phase in ("prepare-promotion", "promote", "tap", "cleanup"):
            result = self.run_phase(phase)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(self.private.exists())
        clone = next(call for call in self.calls() if call["tool"] == "git" and call["args"][0] == "clone")
        self.assertEqual(clone["args"][2], "https://github.com/Se7enbrc/homebrew-glimmer.git")
        tap = next(call for call in self.calls() if call["tool"] == "homebrew-bump.sh")
        self.assertEqual(tap["args"], ["2026.10.6", "2026.10.6-rc.1"])

    def test_failed_precommit_stops_before_verify_and_cannot_authorize_build(self):
        self.assertEqual(self.run_phase("checks").returncode, 0)
        self.env["FIXTURE_FAIL"] = "pre-commit:run --all-files"
        self.assertNotEqual(self.run_phase("verify").returncode, 0)
        self.env.pop("FIXTURE_FAIL")
        self.assertNotEqual(self.run_phase("build").returncode, 0)
        calls = self.calls()
        hook = next(call for call in calls if call["tool"] == "pre-commit")
        self.assertEqual(hook["scan_all_files"], "1")
        self.assertFalse(any(call["tool"] == "make" and call["args"] == ["verify"] for call in calls))
        self.assertFalse(self.private.exists())

    def test_signing_failure_reaps_temporary_keychain_and_files(self):
        self.built()
        self.env["FIXTURE_FAIL"] = "make:CONFIG=Release -o app -o embed-helper preflight notarize"
        result = self.run_phase("sign")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.private.exists())
        setup = next(call for call in self.calls() if call["args"] == ["codesign-setup", "setup-notary"])
        self.assertTrue(setup["secret_env_removed"])
        self.assertTrue(all(mode == 0o600 for mode in setup["modes"].values()))
        self.assertTrue(any(call["tool"] == "security" and call["args"][0] == "delete-keychain"
                            for call in self.calls()))
        self.assertNotIn("fixture-password", result.stdout + result.stderr)

    def test_moved_main_after_verify_cannot_sign(self):
        self.built()
        self.env["FIXTURE_MAIN"] = "b" * 40
        self.assertNotEqual(self.run_phase("sign").returncode, 0)
        self.assertFalse(self.private.exists())

    def test_publication_token_is_not_written_and_helper_restricts_host(self):
        self.packaged()
        self.env["FIXTURE_FAIL_PUBLISH"] = "1"
        result = self.run_phase("publish")
        self.assertNotEqual(result.returncode, 0)
        publication = next(call for call in self.calls() if call["tool"] == "publish-release.sh")
        self.assertFalse(publication["helper_contains_token"])
        self.assertTrue(publication["github.com"])
        self.assertFalse(publication["untrusted.example"])
        self.assertEqual(publication["credential_mode"], 0o600)
        self.assertFalse(self.private.exists())
        self.assertNotIn(self.env["RELEASE_CONTENTS_TOKEN"], result.stdout + result.stderr)

    def test_invalid_material_fails_before_keychain_setup(self):
        self.built()
        self.env["DEVELOPER_ID_P12_BASE64"] = "invalid base64"
        self.assertNotEqual(self.run_phase("sign").returncode, 0)
        self.assertFalse(self.private.exists())
        self.assertFalse(any(call["args"] == ["codesign-setup", "setup-notary"] for call in self.calls()))

    def test_complete_sequence_cleans_each_phase_and_clones_tap_over_https(self):
        self.verified()
        calls = self.calls()
        hook_index = next(index for index, call in enumerate(calls) if call["tool"] == "pre-commit")
        verify_index = next(index for index, call in enumerate(calls)
                            if call["tool"] == "make" and call["args"] == ["verify"])
        self.assertLess(hook_index, verify_index)
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
        self.assertIn(["CONFIG=Release", "-o", "app", "-o", "embed-helper", "preflight", "notarize"], make_args)
        self.assertFalse(any("dist" in args for args in make_args))

    def test_moved_main_before_publish_cannot_expose_update_key(self):
        self.packaged()
        self.env["FIXTURE_MAIN"] = "b" * 40
        self.assertNotEqual(self.run_phase("publish").returncode, 0)
        self.assertFalse(self.private.exists())
        self.assertFalse(any(call["tool"] == "publish-release.sh" for call in self.calls()))

    def test_packaging_outputs_only_the_two_final_assets_and_records_their_bytes(self):
        self.packaged()
        paths = [self.root.resolve() / f"build/dist/Glimmer-2026.10.6.{suffix}" for suffix in ("dmg", "zip")]
        output = Path(self.env["GITHUB_OUTPUT"]).read_text()
        self.assertEqual(output, f"dmg-path={paths[0]}\nzip-path={paths[1]}\n")
        digests = (self.runner / "glimmer-verified-12-1-packaged-artifacts").read_text()
        self.assertEqual(len(digests.splitlines()), 2)
        for path in paths:
            self.assertIn(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path}\n", digests)

    def test_changed_or_missing_packaged_assets_stop_before_publication_credentials(self):
        self.packaged()
        for suffix in ("dmg", "zip"):
            path = self.root / f"build/dist/Glimmer-2026.10.6.{suffix}"
            original = path.read_bytes()
            for change in ("changed", "empty", "missing"):
                with self.subTest(suffix=suffix, change=change):
                    if change == "missing":
                        path.unlink()
                    else:
                        path.write_bytes(b"changed" if change == "changed" else b"")
                    result = self.run_phase("publish")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(self.private.exists())
                    self.assertFalse(any(call["tool"] == "publish-release.sh" for call in self.calls()))
                    path.write_bytes(original)

    def test_missing_or_incomplete_digests_stop_before_publication_credentials(self):
        self.packaged()
        path = self.runner / "glimmer-verified-12-1-packaged-artifacts"
        original = path.read_text()
        for contents in (None, "", original.splitlines()[0] + "\n"):
            with self.subTest(contents=contents):
                if contents is None:
                    path.unlink()
                else:
                    path.write_text(contents)
                self.assertNotEqual(self.run_phase("publish").returncode, 0)
                self.assertFalse(self.private.exists())
                self.assertFalse(any(call["tool"] == "publish-release.sh" for call in self.calls()))

    def test_missing_attestation_stops_before_publication_credentials(self):
        self.packaged()
        for value in ("", "not-confirmed"):
            with self.subTest(value=value):
                self.env["RELEASE_ATTESTATION_ID"] = value
                self.assertNotEqual(self.run_phase("publish").returncode, 0)
                self.assertFalse(self.private.exists())
                self.assertFalse(any(call["tool"] == "publish-release.sh" for call in self.calls()))

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
        self.assertFalse(any(call["args"] == ["codesign-setup", "setup-notary"] for call in self.calls()))

    def test_failed_unsigned_build_cannot_authorize_signing(self):
        self.verified()
        self.env["FIXTURE_FAIL"] = "make:CONFIG=Release guard-release-version clean app embed-helper"
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
        self.env["FIXTURE_FAIL"] = "make:CONFIG=Release -o app -o embed-helper preflight notarize"
        self.env["FIXTURE_FAIL_DELETE"] = "1"
        result = self.run_phase("sign")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.private.exists())
        self.assertFalse((self.runner / "glimmer-verified-12-1-signed").exists())
