# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Candidate and promotion invariants, using inert publication tools."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

import test_release
from test_release import SCRIPTS, channel
from release_validation import SPARKLE, validate_feed


def candidate(short="2026.10.6", build="20261010"):
    feed = channel(short, build)
    ET.SubElement(feed[0], f"{{{SPARKLE}}}channel").text = "rc"
    ET.SubElement(feed[0], "title").text = f"{short} (RC 1)"
    return feed


class CandidateFeedTests(unittest.TestCase):
    def test_only_explicit_candidates_can_repeat_an_unreleased_marketing_version(self):
        feed = candidate()
        self.assertIsNone(validate_feed(feed, "2026.10.6", "20261011", "rc"))
        with self.assertRaises(ValueError):
            validate_feed(feed, "2026.10.6", "20261011")
        with self.assertRaises(ValueError):
            validate_feed(channel("2026.10.6", "20261010"), "2026.10.6", "20261011", "rc")

    def test_candidates_cannot_reuse_or_reverse_any_published_build(self):
        feed = candidate()
        feed.append(channel("2026.10.5", "20261009")[0])
        for build in ("20261008", "20261009", "20261010"):
            with self.subTest(build=build), self.assertRaises(ValueError):
                validate_feed(feed, "2026.10.7", build, "rc")
        feed.append(candidate()[0])
        with self.assertRaisesRegex(ValueError, "duplicate published build"):
            validate_feed(feed, "2026.10.7", "20261011", "rc")

    def test_promotion_requires_existing_latest_candidate_and_explicit_mode(self):
        feed = candidate()
        with self.assertRaises(ValueError):
            validate_feed(feed, "2026.10.6", "20261010")
        self.assertIs(validate_feed(feed, "2026.10.6", "20261010", promote=True), feed[0])
        with self.assertRaises(ValueError):
            validate_feed(feed, "2026.10.6", "20261011", promote=True)
        feed.append(candidate(build="20261011")[0])
        with self.assertRaises(ValueError):
            validate_feed(feed, "2026.10.6", "20261010", promote=True)
        self.assertIs(validate_feed(feed, "2026.10.6", "20261011", promote=True), feed[1])

    def test_stable_release_cannot_be_demoted_to_candidate(self):
        with self.assertRaises(ValueError):
            validate_feed(channel(), "2026.10.5", "20261008", "rc")

    def test_promotion_preserves_enclosure_and_all_other_items_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            feed = candidate()
            feed.append(channel()[0])
            root = ET.Element("rss")
            root.append(feed)
            ET.ElementTree(root).write(path)
            command = [sys.executable, str(SCRIPTS / "update-appcast.py"), str(path),
                       "--short-version", "2026.10.6", "--version", "20261010",
                       "--url", "https://example.test/app.zip", "--ed-signature", "test",
                       "--length", "10", "--promote"]
            original = path.read_bytes()
            for option, changed in (("--url", "https://example.test/other.zip"),
                                    ("--ed-signature", "changed"), ("--length", "11")):
                bad = command.copy()
                bad[bad.index(option) + 1] = changed
                result = subprocess.run(bad, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(path.read_bytes(), original)
            result = subprocess.run(command, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            promoted = ET.parse(path).getroot().find("channel")
            self.assertIsNone(promoted[0].find(f"{{{SPARKLE}}}channel"))
            self.assertEqual(promoted[0].findtext("title"), "2026.10.6")
            self.assertEqual(promoted[0].find("enclosure").attrib, feed[0].find("enclosure").attrib)
            self.assertEqual([(e.tag, (e.text or "").strip(), e.attrib) for e in promoted[1]],
                             [(e.tag, (e.text or "").strip(), e.attrib) for e in feed[1]])
            unchanged = path.read_bytes()
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(path.read_bytes(), unchanged)


class CandidatePublicationTests(unittest.TestCase):
    def setUp(self):
        test_release.ReleasePublicationTests.setUp(self)

    def configure_candidate(self):
        self.env.update(GITHUB_ACTIONS="true", GITHUB_SHA="a" * 40, EXPECTED_SHA="a" * 40,
                        FIXTURE_ROOT=str(self.root))
        self.env.pop("GLIMMER_RELEASE_CHANNEL", None)
        self.source_feed = self.root / "appcast.xml"
        self.source_feed.write_text("candidate checkout feed must remain unchanged\n")
        live_feed = ET.Element("rss")
        live_feed.append(channel("2026.10.5", "399"))
        ET.ElementTree(live_feed).write(self.root / "live-appcast.xml")
        for script in ("update-appcast.py", "release_validation.py", "changelog.py"):
            shutil.copy2(SCRIPTS / script, self.root / "scripts" / script)
        (self.root / "scripts/validate_actual.py").write_text(
            'import sys\nfrom pathlib import Path\nimport xml.etree.ElementTree as ET\n'
            'from release_validation import validate_feed\n'
            'args=sys.argv[1:]\n'
            'validate_feed(ET.parse(args[args.index("--appcast")+1]).getroot().find("channel"),'
            ' "2026.10.6", "400", args[args.index("--channel")+1])\n')
        os.rename(self.root / "scripts/release_validation.py", self.root / "scripts/release_validation_actual.py")
        (self.root / "scripts/release_validation.py").write_text(
            'from release_validation_actual import *\n'
            'if __name__ == "__main__":\n'
            '    exec(open(__file__.replace("release_validation.py", "validate_actual.py")).read())\n')
        (self.root).joinpath("scripts/verify-update-signature.swift").write_text("#!/bin/sh\nexit 0\n")
        (self.root).joinpath("scripts/verify-update-signature.swift").chmod(0o755)
        self.write_tool("bin/git", '''#!/bin/bash
shift 2
case "$1" in
    fetch) [ "$5" = +refs/heads/appcast:refs/remotes/origin/appcast ] ;;
    rev-parse)
        case "$2" in
            origin/main) printf '%040d\\n' 0 | tr 0 b ;;
            origin/appcast) printf '%040d\\n' 0 | tr 0 e ;;
            *) printf '%040d\\n' 0 | tr 0 a ;;
        esac ;;
    show)
        if [ "$2" = eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee:appcast.xml ]; then cat "$FIXTURE_ROOT/live-appcast.xml";
        elif [[ "$2" = *:appcast.xml ]]; then exit 1;
        else printf 'MARKETING_VERSION = 2026.10.6\\n'; fi ;;
    *) exit 1 ;;
esac
''')
        self.write_tool("tools/sign_update", '#!/bin/bash\ncat >/dev/null\n'
                        'printf \'sparkle:edSignature="fixture" length="21"\\n\'\n')
        self.write_tool("bin/gh", f'#!{sys.executable}\n' + '''import json, os, pathlib, sys
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
args = sys.argv[1:]
with (root / "gh-calls").open("a") as log:
    log.write(json.dumps(args) + "\\n")
state = root / "release-state"
if args[:2] == ["release", "create"]:
    state.write_text("draft" if "--draft" in args else "published")
elif args[:2] == ["release", "edit"] and "--draft=false" in args:
    state.write_text("published")
elif args[:2] == ["release", "view"]:
    if not state.exists():
        sys.exit(1)
    print(7)
elif args[0] == "api":
    # Like GitHub: the by-tag endpoint can't see a draft.
    if "/releases/tags/" in args[1] and state.read_text() == "draft":
        sys.exit(1)
    if "/commits/" in args[1]:
        print("a" * 40)
    elif ".draft" in args:
        print("true" if state.read_text() == "draft" else "false")
    elif any(".assets" in arg for arg in args):
        pass
    else:
        print("true")
''')
        (self.root / "scripts/github_signed_commit.py").write_text('''import json, os, pathlib, sys
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
(root / "committed-feed.xml").write_bytes(pathlib.Path(sys.argv[5]).read_bytes())
(root / "commit-args").write_text(json.dumps(sys.argv[1:]))
print("c" * 40)
''')

    def write_tool(self, name, text):
        path = self.root / name
        path.write_text(text)
        path.chmod(0o755)

    def publish_candidate(self, tag="2026.10.6-rc.1"):
        return subprocess.run(["bash", str(self.root / "scripts/publish-release.sh"),
                               "2026.10.6", "400", str(self.root / "Glimmer.app"),
                               str(self.root / "dist"), "fixture/glimmer", tag],
                              env=self.env, capture_output=True, text=True, timeout=10)

    def test_candidate_uses_appcast_branch_feed_and_cas_without_changing_source_checkout(self):
        self.configure_candidate()
        (self.root / "dist/Glimmer-2026.10.6.intoto.jsonl").write_text("{}\n")
        original = self.source_feed.read_bytes()
        result = self.publish_candidate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.source_feed.read_bytes(), original)
        args = json.loads((self.root / "commit-args").read_text())
        self.assertEqual(args[:4], ["fixture/glimmer", "appcast", "e" * 40, "appcast.xml"])
        feed = ET.parse(self.root / "committed-feed.xml").getroot().find("channel")
        self.assertEqual(feed[0].findtext(f"{{{SPARKLE}}}channel"), "rc")
        self.assertEqual(feed[0].findtext(f"{{{SPARKLE}}}shortVersionString"), "2026.10.6")
        self.assertIn("/2026.10.6-rc.1/", feed[0].find("enclosure").get("url"))
        self.assertEqual(feed[1].findtext(f"{{{SPARKLE}}}version"), "399")
        calls = [json.loads(line) for line in (self.root / "gh-calls").read_text().splitlines()]
        create = next(call for call in calls if call[:2] == ["release", "create"])
        for flag in ("--draft", "--prerelease", "--latest=false", "--verify-tag"):
            self.assertIn(flag, create)
        self.assertNotIn("--target", create)
        edit = next(call for call in calls if call[:2] == ["release", "edit"])
        self.assertIn("--latest=false", edit)
        self.assertIn("--draft=false", edit)
        self.assertEqual((self.root / "release-state").read_text(), "published")
        upload = next(call for call in calls if call[:2] == ["release", "upload"])
        self.assertTrue(upload[3].endswith("/Glimmer-2026.10.6.intoto.jsonl"))
        self.assertFalse(Path(self.env["FIXTURE_DITTO_MARKER"]).exists())

    def test_candidate_requires_hosted_context_and_exact_version_tag_before_credentials(self):
        for tag in ("2026.10.7-rc.1", "2026.10.6-rc.0", "2026.10.6-rc.1;evil", "2026.10.6-rc.1"):
            with self.subTest(tag=tag):
                result = self.publish_candidate(tag)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(Path(self.env["FIXTURE_CREDS_MARKER"]).exists())

    def test_candidate_rechecks_latest_published_build_before_reading_signing_key(self):
        self.configure_candidate()
        root = ET.Element("rss")
        root.append(candidate(build="401"))
        ET.ElementTree(root).write(self.root / "live-appcast.xml")
        result = self.publish_candidate()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(Path(self.env["FIXTURE_CREDS_MARKER"]).exists())

    def test_candidate_source_and_precreated_tag_must_match_before_signing(self):
        self.configure_candidate()
        self.env["EXPECTED_SHA"] = "d" * 40
        self.assertNotEqual(self.publish_candidate().returncode, 0)
        self.assertFalse(Path(self.env["FIXTURE_CREDS_MARKER"]).exists())
        self.env["EXPECTED_SHA"] = "a" * 40
        self.write_tool("bin/gh", '#!/bin/bash\nprintf "%040d\\n" 0 | tr 0 d\n')
        self.assertNotEqual(self.publish_candidate().returncode, 0)
        self.assertFalse(Path(self.env["FIXTURE_CREDS_MARKER"]).exists())


if __name__ == "__main__":
    unittest.main()
