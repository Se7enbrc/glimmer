"""Regression tests for release gates; no network, signing keys, or publishing."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from release_validation import SPARKLE, validate_bundle, validate_distribution, validate_feed


def channel(short="2026.10.5", build="20261008"):
    return ET.fromstring(f'''<channel xmlns:sparkle="{SPARKLE}"><item>
        <sparkle:version>{build}</sparkle:version>
        <sparkle:shortVersionString>{short}</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
        <enclosure url="https://example.test/app.zip" sparkle:edSignature="test" length="10" />
        </item></channel>''')


class ReleaseValidationTests(unittest.TestCase):
    def test_sparkle_zip_target_packages_explicit_bundle_without_signing(self):
        with tempfile.TemporaryDirectory(prefix="glimmer zip fixture ") as directory:
            root = Path(directory)
            (root / "Glimmer").mkdir()
            (root / "Glimmer/Version.xcconfig").write_text(
                "MARKETING_VERSION = 2026.10.6\nCURRENT_PROJECT_VERSION = 400\n")
            shutil.copy2(SCRIPTS.parent / "Makefile", root / "Makefile")
            app = root / "prepared app/Glimmer.app"
            app.mkdir(parents=True)
            output = root / "prepared assets"
            tools = root / "bin"
            tools.mkdir()
            log = root / "ditto-args.json"
            (tools / "ditto").write_text(f'#!{sys.executable}\n'
                                        'import json, os, pathlib, sys\n'
                                        'pathlib.Path(os.environ["FIXTURE_LOG"]).write_text(json.dumps(sys.argv[1:]))\n'
                                        'pathlib.Path(sys.argv[-1]).write_bytes(b"inert zip")\n')
            for name in ("xcrun", "security"):
                (tools / name).write_text("#!/bin/bash\nexit 1\n")
            for tool in tools.iterdir():
                tool.chmod(0o755)
            result = subprocess.run(["/usr/bin/make", "sparkle-zip", "CONFIG=Release",
                                     f"GLIMMER_APP_SRC={app}", f"DIST_DIR={output}"], cwd=root,
                                    env={"PATH": f"{tools}:/usr/bin:/bin", "HOME": str(root),
                                         "FIXTURE_LOG": str(log)}, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(log.read_text()),
                             ["-c", "-k", "--sequesterRsrc", "--keepParent", str(app),
                              str(output / "Glimmer-2026.10.6.zip")])
            self.assertEqual((output / "Glimmer-2026.10.6.zip").read_bytes(), b"inert zip")

    def test_local_suite_filter_cannot_narrow_the_full_gate(self):
        # The default gate, not one inherited from an outer make such as a COVERAGE=1 run.
        clean = {k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "COVERAGE")}

        def plan(target):
            return subprocess.run(["make", "--dry-run", target, "TEST_SUITE=DatagramBatchTests"], env=clean,
                                  cwd=SCRIPTS.parent, capture_output=True, text=True, check=True).stdout
        self.assertIn("-only-testing:GlimmerTests/DatagramBatchTests", plan("test"))
        full = plan("verify")
        commands = [line for line in full.replace("\\\n", " ").splitlines() if line.startswith("xcodebuild test ")]
        self.assertEqual(len(commands), 2)
        self.assertNotIn("-only-testing:", commands[0])
        self.assertNotIn("-only-testing:GlimmerTests/DatagramBatchTests", full)
        self.assertIn("-enableAddressSanitizer YES", commands[1])
        self.assertIn("-only-testing:GlimmerTests/FuzzTests", commands[1])
        self.assertIn("-only-testing:GlimmerTests/StreamFuzzTests", commands[1])
        self.assertIn("swiftlint lint --strict", full)
        self.assertIn("python3 -m unittest", full)

    def test_sparkle_app_and_release_tools_share_a_pinned_version(self):
        root = SCRIPTS.parent
        resolved = json.loads((root / "Glimmer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
        version = next(pin["state"]["version"] for pin in resolved["pins"] if pin["identity"] == "sparkle")
        make_version = re.search(r"^SPARKLE_VERSION \?= (\S+)$", (root / "Makefile").read_text(), re.MULTILINE)
        tools = (SCRIPTS / "sparkle-tools.sh").read_text()
        tool_version = re.search(r'^SPARKLE_VERSION="\$\{SPARKLE_VERSION:-([^}]+)\}"$', tools, re.MULTILINE)
        trusted = re.search(r'if \[ "\$SPARKLE_VERSION" = "([^"]+)" \]; then\s+SHA256="([a-f0-9]{64})"', tools)
        self.assertIsNotNone(make_version, "Makefile must pin the Sparkle tool version")
        self.assertIsNotNone(tool_version, "sparkle-tools.sh must pin its default version")
        self.assertIsNotNone(trusted, "Sparkle tools require a trusted pinned archive digest")
        self.assertEqual(make_version[1], version, "Update release tools alongside the Sparkle app dependency")
        self.assertEqual(tool_version[1], version, "Update the standalone Sparkle tool default")
        self.assertEqual(trusted[1], version, "Pin the trusted digest for the updated Sparkle tool archive")

    def test_new_build_must_advance(self):
        for build in ("20261007", "20261008"):
            with self.subTest(build=build), self.assertRaises(ValueError):
                validate_feed(channel(), "2026.10.6", build)
        self.assertIsNone(validate_feed(channel(), "2026.10.6", "20261009"))

    def test_exact_retry_is_allowed(self):
        feed = channel()
        self.assertIs(validate_feed(feed, "2026.10.5", "20261008"), feed[0])

    def test_release_cannot_change_build(self):
        with self.assertRaises(ValueError):
            validate_feed(channel(), "2026.10.5", "20261009")

    def test_checks_all_items_not_just_the_first(self):
        feed = channel()
        feed.append(channel("2026.10.6", "20261009")[0])
        with self.assertRaises(ValueError):
            validate_feed(feed, "2026.10.7", "20261009")

    def test_rejects_malformed_builds(self):
        for build in ("", "0", "-1", "20261008.1", "abc"):
            with self.subTest(build=build), self.assertRaises(ValueError):
                validate_feed(channel(), "2026.10.6", build)
        with self.assertRaises(ValueError):
            validate_feed(channel(build="oops"), "2026.10.6", "20261009")

    def test_stale_bundle_build_is_rejected(self):
        info = {"CFBundleShortVersionString": "2026.10.6", "CFBundleVersion": "20261008"}
        with self.assertRaises(ValueError):
            validate_bundle(info, "2026.10.6", "20261009")
        info["CFBundleVersion"] = "20261009"
        validate_bundle(info, "2026.10.6", "20261009")
        with self.assertRaises(ValueError):
            validate_bundle(info, "2026.10.7", "20261009")

    def test_distribution_requires_trust_and_real_app_and_helper_launch(self):
        with patch("release_validation.subprocess.run") as run:
            validate_distribution("/fixture/Glimmer.app")
        self.assertEqual([call.args[0][0] for call in run.call_args_list],
                         ["/usr/bin/codesign", "/usr/bin/xcrun", "/usr/sbin/spctl",
                          "/fixture/Glimmer.app/Contents/MacOS/Glimmer",
                          "/fixture/Glimmer.app/Contents/Library/LaunchServices/Glimmer Network Helper.app/Contents/MacOS/io.ugfugl.glimmer.helper"])
        self.assertEqual(run.call_args_list[3].args[0][-1], "help")
        self.assertEqual(run.call_args_list[4].args[0][-1], "--check-launch")
        for call in run.call_args_list:
            self.assertTrue(call.kwargs["check"])
            self.assertEqual(call.kwargs["timeout"], 30)

    def test_distribution_stops_at_each_failed_validation(self):
        for index in range(5):
            with self.subTest(index=index):
                failure = subprocess.CalledProcessError(1, "validator", stderr="rejected")
                with patch("release_validation.subprocess.run",
                           side_effect=[None] * index + [failure]) as run:
                    with self.assertRaisesRegex(ValueError, "rejected"):
                        validate_distribution("/fixture/Glimmer.app")
                self.assertEqual(run.call_count, index + 1)

    def test_notarized_but_amfi_killed_app_cannot_pass_distribution_gate(self):
        failure = subprocess.CalledProcessError(-9, "Glimmer", stderr="")
        with patch("release_validation.subprocess.run", side_effect=[None] * 3 + [failure]) as run:
            with self.assertRaisesRegex(ValueError, "Glimmer rejected"):
                validate_distribution("/fixture/Glimmer.app")
        self.assertEqual(run.call_count, 4)

    def test_hung_or_missing_launch_probe_fails_closed(self):
        for failure in (subprocess.TimeoutExpired("Glimmer", 30), FileNotFoundError("missing")):
            with self.subTest(failure=failure), patch("release_validation.subprocess.run", side_effect=failure):
                with self.assertRaises(ValueError):
                    validate_distribution("/fixture/Glimmer.app")

    def test_appcast_retry_preserves_bytes_and_rejects_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            original = ET.tostring(channel(), encoding="unicode")
            original = "<rss>" + original + "</rss>\n"
            path.write_text(original)
            command = [sys.executable, str(SCRIPTS / "update-appcast.py"), str(path),
                       "--short-version", "2026.10.5", "--version", "20261008",
                       "--url", "https://example.test/app.zip", "--ed-signature", "test", "--length", "10"]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(path.read_text(), original)
            command[-1] = "11"
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(path.read_text(), original)

    def test_tampered_tool_archive_is_not_extracted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            curl = root / "curl"
            curl.write_text('#!/bin/bash\nprintf tampered > "$4"\n')
            curl.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:/usr/bin:/bin", SPARKLE_VERSION="test",
                       SPARKLE_SHA256=hashlib.sha256(b"trusted").hexdigest(),
                       GLIMMER_SPARKLE_CACHE=str(root / "cache"))
            result = subprocess.run(["bash", str(SCRIPTS / "sparkle-tools.sh")], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"checksum mismatch", result.stderr)
            self.assertFalse((root / "cache/test/.verified-sha256").exists())


class ReleaseVersionGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "Version.xcconfig"
        self.config.write_text("MARKETING_VERSION = 2026.10.6\nCURRENT_PROJECT_VERSION = 20261009\n")
        self.appcast = self.root / "appcast.xml"
        self.appcast.write_text("<rss>" + ET.tostring(channel(), encoding="unicode") + "</rss>")
        self.app = self.root / "Glimmer.app"
        (self.app / "Contents").mkdir(parents=True)
        self.plist(short="2026.10.6", build="20261009")

    def plist(self, short, build):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(
            {"CFBundleShortVersionString": short, "CFBundleVersion": build}))

    def gate(self, *args, env=None):
        return subprocess.run([sys.executable, str(SCRIPTS / "release_validation.py"), "--config", str(self.config),
                               "--appcast", str(self.appcast), *args], capture_output=True, text=True,
                              env={**os.environ, "GLIMMER_RELEASE_CHANNEL": "", **(env or {})})

    def test_matching_config_and_bundle_pass_and_print_the_versions(self):
        result = self.gate("--app", str(self.app), "--short-version", "2026.10.6", "--build", "20261009")
        self.assertEqual((result.returncode, result.stdout),
                         (0, "Release versions verified: 2026.10.6 (20261009)\n"))

    def test_advertised_version_or_build_must_match_the_config(self):
        for args, message in ((["--short-version", "2026.10.7"], "advertised release version"),
                              (["--build", "20261010"], "advertised build number")):
            result = self.gate(*args)
            with self.subTest(args=args):
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)

    def test_unusable_inputs_fail_closed_with_an_error_line(self):
        self.config.write_text("MARKETING_VERSION = 2026.10.6\n")
        self.assertIn("ERR:", self.gate().stderr)
        self.config.write_text("MARKETING_VERSION = 2026.10.6\nCURRENT_PROJECT_VERSION = 20261001\n")
        self.assertIn("must exceed published build", self.gate().stderr)
        self.config.write_text("MARKETING_VERSION = 2026.10.6\nCURRENT_PROJECT_VERSION = 20261009\n")
        self.appcast.write_text("<rss/>")
        self.assertIn("appcast has no channel", self.gate().stderr)
        self.appcast.write_text("not xml")
        self.assertEqual(self.gate().returncode, 1)
        self.config.unlink()
        self.assertEqual(self.gate().returncode, 1)

    def test_stale_bundle_or_missing_plist_and_misused_flags_are_refused(self):
        self.plist(short="2026.10.6", build="20261008")
        result = self.gate("--app", str(self.app))
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match 20261009; rebuild", result.stderr)
        (self.app / "Contents/Info.plist").unlink()
        self.assertEqual(self.gate("--app", str(self.app)).returncode, 1)
        result = self.gate("--validate-distribution")
        self.assertEqual(result.returncode, 2)
        self.assertIn("--validate-distribution requires --app", result.stderr)

    def test_release_channel_comes_from_the_environment_and_must_be_known(self):
        self.assertEqual(self.gate(env={"GLIMMER_RELEASE_CHANNEL": "rc"}).returncode, 0)
        result = self.gate(env={"GLIMMER_RELEASE_CHANNEL": "beta"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("ERR:", result.stderr)

    def test_malformed_version_or_build_is_rejected_before_any_artifact_work(self):
        for values, message in (("MARKETING_VERSION = 2026.10\nCURRENT_PROJECT_VERSION = 20261009\n", "YYYY.M.MICRO"),
                                ("MARKETING_VERSION = 2026.10.6\nCURRENT_PROJECT_VERSION = 0\n", "positive integer")):
            self.config.write_text(values)
            self.assertIn(message, self.gate().stderr)


class ReleasePublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="glimmer publish fixture ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("scripts", "Glimmer", "bin", "tools", "dist", "Glimmer.app/Contents"):
            (self.root / name).mkdir(parents=True)
        shutil.copy2(SCRIPTS / "publish-release.sh", self.root / "scripts/publish-release.sh")
        (self.root / "Glimmer/Version.xcconfig").write_text(
            "MARKETING_VERSION = 2026.10.6\nCURRENT_PROJECT_VERSION = 400\n")
        (self.root / "Glimmer.app/Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "2026.10.6", "CFBundleVersion": "400"}))
        (self.root / "dist/Glimmer-2026.10.6.dmg").write_bytes(b"inert fixture")
        self.zip = self.root / "dist/Glimmer-2026.10.6.zip"
        self.zip.write_bytes(b"prepared update bytes")
        (self.root / "scripts/release_validation.py").write_text("raise SystemExit(0)\n")
        (self.root).joinpath("scripts/verify-update-signature.swift").write_text("#!/bin/sh\nexit 0\n")
        (self.root).joinpath("scripts/verify-update-signature.swift").chmod(0o755)
        stubs = {
            "bin/make": "exit 0\n",
            "bin/git": '''shift 2
case "$1" in
    fetch) exit 0 ;;
    rev-parse) printf '%s\\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
    show) printf 'MARKETING_VERSION = 2026.10.6\\n' ;;
    *) exit 1 ;;
esac
''',
            "bin/ditto": 'touch "$FIXTURE_DITTO_MARKER"\nexit 1\n',
            "bin/gh": 'touch "$FIXTURE_PUBLISH_MARKER"\nexit 1\n',
            "scripts/signing-creds.sh": 'touch "$FIXTURE_CREDS_MARKER"\nprintf "%s\\n" "$FIXTURE_SIGNER_SECRET"\n',
            "scripts/sparkle-tools.sh": 'printf "%s\\n" "$FIXTURE_TOOLS"\n',
            "tools/sign_update": '''cat >/dev/null
printf 'signer stdout: %s\\n' "$FIXTURE_SIGNER_SECRET"
printf 'signer stderr: %s\\n' "$FIXTURE_SIGNER_SECRET" >&2
exit 1
''',
        }
        for name, contents in stubs.items():
            path = self.root / name
            path.write_text("#!/bin/bash\n" + contents)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.root / 'bin'}:{os.environ['PATH']}",
                        FIXTURE_TOOLS=str(self.root / "tools"), FIXTURE_SIGNER_SECRET="inert-sensitive-signing-value",
                        FIXTURE_PUBLISH_MARKER=str(self.root / "publication-attempted"),
                        FIXTURE_CREDS_MARKER=str(self.root / "credentials-read"),
                        FIXTURE_DITTO_MARKER=str(self.root / "zip-recreated"),
                        FIXTURE_SIGNED_ZIP=str(self.root / "signed-update"))

    def publish(self):
        return subprocess.run(["bash", str(self.root / "scripts/publish-release.sh"),
                               "2026.10.6", "400", str(self.root / "Glimmer.app"),
                               str(self.root / "dist"), "fixture/glimmer"],
                              env=self.env, capture_output=True, text=True, timeout=10)

    def test_signer_failure_withholds_both_streams_and_stops_publication(self):
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("update signing failed", result.stderr)
        self.assertIn("Nothing published", result.stderr)
        for withheld in (self.env["FIXTURE_SIGNER_SECRET"], "signer stdout:", "signer stderr:"):
            self.assertNotIn(withheld, result.stdout + result.stderr)
        self.assertFalse(Path(self.env["FIXTURE_PUBLISH_MARKER"]).exists())

    def test_publication_signs_prepared_zip_without_recreating_it(self):
        signer = self.root / "tools/sign_update"
        signer.write_text('#!/bin/bash\ncat >/dev/null\ncp "${@: -1}" "$FIXTURE_SIGNED_ZIP"\n'
                          'printf \'sparkle:edSignature="fixture" length="21"\\n\'\n')
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(Path(self.env["FIXTURE_PUBLISH_MARKER"]).exists())
        self.assertEqual(Path(self.env["FIXTURE_SIGNED_ZIP"]).read_bytes(), b"prepared update bytes")
        self.assertEqual(self.zip.read_bytes(), b"prepared update bytes")
        self.assertFalse(Path(self.env["FIXTURE_DITTO_MARKER"]).exists())

    def test_signature_the_app_would_reject_stops_publication(self):
        (self.root / "tools/sign_update").write_text(
            '#!/bin/bash\ncat >/dev/null\nprintf \'sparkle:edSignature="fixture" length="21"\\n\'\n')
        (self.root / "scripts/verify-update-signature.swift").write_text("#!/bin/sh\nexit 1\n")
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("doesn't match the app's SUPublicEDKey", result.stderr)
        self.assertFalse(Path(self.env["FIXTURE_PUBLISH_MARKER"]).exists())

    def test_missing_or_empty_prepared_zip_stops_before_credentials(self):
        for missing in (True, False):
            with self.subTest(missing=missing):
                if missing:
                    self.zip.unlink()
                else:
                    self.zip.write_bytes(b"")
                result = self.publish()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("prepared Sparkle ZIP missing", result.stderr)
                for name in ("FIXTURE_CREDS_MARKER", "FIXTURE_DITTO_MARKER", "FIXTURE_PUBLISH_MARKER"):
                    self.assertFalse(Path(self.env[name]).exists())


class BuildInfoTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "scripts").mkdir()
        (self.root / "Glimmer").mkdir()
        (self.root / ".fixture-bin").mkdir()
        (self.root / "scripts/generate-build-info.sh").write_bytes((SCRIPTS / "generate-build-info.sh").read_bytes())
        (self.root / ".gitignore").write_text("Glimmer/BuildInfo.generated.swift\n.fixture-bin/\n")
        (self.root / "Glimmer/example.swift").write_text("let value = 1\n")
        clock = self.root / ".fixture-bin/date"
        clock.write_text('#!/bin/bash\nprintf "%s\\n" "$FIXTURE_DATE"\n')
        clock.chmod(0o755)
        self.git("init", "-q")
        self.git("config", "--local", "commit.gpgsign", "false")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                 "commit", "-qm", "fixture")

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)

    def stamp(self, timestamp):
        env = dict(os.environ, PATH=f"{self.root / '.fixture-bin'}:{os.environ['PATH']}", FIXTURE_DATE=timestamp)
        subprocess.run(["bash", str(self.root / "scripts/generate-build-info.sh")],
                       check=True, capture_output=True, env=env)
        return (self.root / "Glimmer/BuildInfo.generated.swift").read_text()

    def test_clean_commit_reuses_its_stamp(self):
        first = self.stamp("2026-10-09T14:00:00Z")
        self.assertNotRegex(first, r'static let commit = "[^"]*-dirty"')
        self.assertEqual(first, self.stamp("2026-10-09T14:01:00Z"))

    def test_dirty_builds_refresh_time_and_include_untracked_sources(self):
        self.stamp("2026-10-09T14:00:00Z")
        (self.root / "Glimmer/new.swift").write_text("let added = 1\n")
        first = self.stamp("2026-10-09T14:01:00Z")
        self.assertRegex(first, r'static let commit = "[^"]*-dirty"')
        (self.root / "Glimmer/example.swift").write_text("let value = 2\n")
        second = self.stamp("2026-10-09T14:02:00Z")
        self.assertIn('2026-10-09T14:02:00Z', second)
        self.assertNotEqual(first, second)


if __name__ == "__main__":
    unittest.main()
