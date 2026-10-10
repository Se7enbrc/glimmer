# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Signing orchestration checks with inert profile and codesign substitutes."""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SIGN_SCRIPT = Path(__file__).resolve().parents[1] / "sign-bundle.sh"

PROVISION_STUB = r'''
import json, os, pathlib, plistlib, sys
args = dict(zip(sys.argv[2::2], sys.argv[3::2]))
profile = pathlib.Path(args["--profile"])
with open(os.environ["SIGN_TEST_LOG"], "a") as log:
    log.write(json.dumps({"tool": "provision", "args": args}) + "\n")
if not profile.is_file() or profile.read_text() == "invalid":
    sys.exit(1)
app = pathlib.Path(args["--app"])
resolved = {"fixture.role": profile.read_text(), "fixture.source": args["--entitlements"]}
pathlib.Path(args["--output-entitlements"]).write_bytes(plistlib.dumps(resolved))
(app / "Contents/embedded.provisionprofile").write_bytes(profile.read_bytes())
'''

CODESIGN_STUB = r'''
import json, os, pathlib, plistlib, sys
args = sys.argv[1:]
record = {"tool": "codesign", "args": args}
if "--entitlements" in args:
    path = pathlib.Path(args[args.index("--entitlements") + 1])
    record["entitlements"] = plistlib.loads(path.read_bytes())
with open(os.environ["SIGN_TEST_LOG"], "a") as log:
    log.write(json.dumps(record) + "\n")
if "--verify" in args and os.environ.get("SIGN_TEST_VERIFY_FAILURE"):
    sys.exit(1)
'''


class SignBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="glimmer signing fixture ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Fake Glimmer.app"
        self.daemon = self.app / "Contents/Library/LaunchServices/Glimmer Network Helper.app"
        self.bin = self.root / "mock tools"
        self.bin.mkdir()
        self.log = self.root / "calls.jsonl"
        for name, source in (("python3", PROVISION_STUB), ("codesign", CODESIGN_STUB)):
            tool = self.bin / name
            tool.write_text(f"#!{sys.executable}\n" + source)
            tool.chmod(0o755)
        self.app_profile = self.root / "app fixture.provisionprofile"
        self.helper_profile = self.root / "helper fixture.provisionprofile"
        self.app_profile.write_text("app")
        self.helper_profile.write_text("helper")
        self.keychain = str(self.root / "mock keychain with spaces.keychain-db")
        self.entitlements = self.root / "app source.entitlements"
        self.entitlements.write_bytes(plistlib.dumps({"fixture.app": True}))
        login_entitlements = self.root / "LoginHelper/LoginHelper.entitlements"
        login_entitlements.parent.mkdir()
        login_entitlements.write_bytes(plistlib.dumps({"fixture.login": True}))
        self.framework = self.app / "Contents/Frameworks/Sparkle.framework"
        self.updater = self.framework / "Versions/B/Updater.app"
        self.updater_binary = self.updater / "Contents/MacOS/Updater"
        self.xpc = self.framework / "Versions/B/XPCServices/Downloader.xpc"
        self.autoupdate = self.framework / "Versions/B/Autoupdate"
        self.login = self.app / "Contents/Library/LoginItems/Glimmer Login Helper.app"
        self.dylib = self.app / "Contents/Frameworks/fixture.dylib"
        for directory in (self.daemon / "Contents", self.xpc, self.login):
            directory.mkdir(parents=True)
        for file in (self.updater_binary, self.autoupdate, self.dylib):
            file.parent.mkdir(parents=True, exist_ok=True)
            file.touch()
        self.environment = {
            **os.environ,
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "TMPDIR": str(self.root) + "/",
            "SIGN_TEST_LOG": str(self.log),
            "GLIMMER_PROVISIONING_PROFILE": str(self.app_profile),
            "GLIMMER_HELPER_PROVISIONING_PROFILE": str(self.helper_profile),
        }
        self.environment.pop("SIGN_TEST_VERIFY_FAILURE", None)

    def run_sign(self, identity="Developer ID Application: Fixture", environment=None):
        return subprocess.run(
            ["/bin/bash", str(SIGN_SCRIPT), str(self.app), identity, self.keychain, str(self.entitlements)],
            cwd=self.root, env=environment or self.environment, capture_output=True, text=True, timeout=10,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_distinct_profiles_entitlements_and_inside_out_order_with_spaces(self):
        result = self.run_sign()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual([call["tool"] for call in calls[:2]], ["provision", "provision"])
        self.assertEqual([call["args"]["--profile"] for call in calls[:2]],
                         [str(self.app_profile), str(self.helper_profile)])
        signatures = [call for call in calls if call["tool"] == "codesign" and "--verify" not in call["args"]]
        self.assertEqual([call["args"][-1] for call in signatures],
                         [str(path) for path in (self.updater_binary, self.updater, self.xpc,
                                                self.autoupdate, self.framework, self.login,
                                                self.dylib, self.daemon, self.app)])
        for call in signatures:
            args = call["args"]
            self.assertNotIn("--deep", args)
            self.assertIn("--timestamp", args)
            self.assertEqual(args[args.index("--keychain") + 1], self.keychain)
            self.assertEqual(args[args.index("--sign") + 1], "Developer ID Application: Fixture")
        self.assertEqual(signatures[-2]["entitlements"]["fixture.role"], "helper")
        self.assertEqual(signatures[-1]["entitlements"]["fixture.role"], "app")
        self.assertEqual(signatures[-2]["entitlements"]["fixture.source"], "helper/Helper.entitlements")
        self.assertEqual(signatures[-1]["entitlements"]["fixture.source"], str(self.entitlements))
        self.assertEqual(signatures[5]["entitlements"], {"fixture.login": True})
        for call in signatures[:4]:
            self.assertIn("--preserve-metadata=entitlements,identifier", call["args"])
            self.assertNotIn("entitlements", call)
        self.assertEqual(calls[-1]["args"], ["--verify", "--deep", "--strict", "--verbose=2", str(self.app)])
        self.assertEqual(list(self.root.glob("glimmer-sign.*")), [])

    def test_ad_hoc_signing_fails_before_provisioning_or_codesign(self):
        result = self.run_sign(identity="-")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_missing_profile_variables_fail_before_codesign(self):
        for key in ("GLIMMER_PROVISIONING_PROFILE", "GLIMMER_HELPER_PROVISIONING_PROFILE"):
            with self.subTest(key=key):
                environment = dict(self.environment)
                environment.pop(key)
                self.assertNotEqual(self.run_sign(environment=environment).returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_missing_or_invalid_profiles_fail_before_any_codesign(self):
        for profile in (self.app_profile, self.helper_profile):
            for state in ("missing", "invalid"):
                with self.subTest(profile=profile.name, state=state):
                    self.log.unlink(missing_ok=True)
                    profile.unlink(missing_ok=True)
                    if state == "invalid":
                        profile.write_text("invalid")
                    self.assertNotEqual(self.run_sign().returncode, 0)
                    self.assertFalse(any(call["tool"] == "codesign" for call in self.calls()))
                    self.assertEqual(list(self.root.glob("glimmer-sign.*")), [])
                    profile.write_text("app" if profile == self.app_profile else "helper")

    def test_failed_final_verification_fails_the_script(self):
        environment = {**self.environment, "SIGN_TEST_VERIFY_FAILURE": "1"}
        self.assertNotEqual(self.run_sign(environment=environment).returncode, 0)
        self.assertEqual(self.calls()[-1]["tool"], "codesign")
        self.assertIn("--verify", self.calls()[-1]["args"])
        self.assertEqual(list(self.root.glob("glimmer-sign.*")), [])


if __name__ == "__main__":
    unittest.main()
