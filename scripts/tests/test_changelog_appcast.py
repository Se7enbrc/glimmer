# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Changelog rendering and appcast publication refuse unsafe or ambiguous input."""

import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import changelog
from release_validation import SPARKLE


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


APPCAST = load("update_appcast", "update-appcast.py")
GAMEDB = load("gen_gamecontrollerdb", "gen-gamecontrollerdb.py")
LOG = """# Changelog

## 2026.10.6 - 2026-10-09

### Fixed

- Pad `a_b` & **bold** [guide](docs/SECURITY.md) and <app>.
  continued _here_.

Plain *tail* line.

## 2026.10.5 - 2026-10-01

- Older note.

## 2026.10.4

"""


def run_main(module, argv):
    out, err = io.StringIO(), io.StringIO()
    code = 0
    with patch.object(sys, "argv", ["x", *argv]), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            module.main()
        except SystemExit as exit_:
            code = exit_.code
    return code, out.getvalue(), err.getvalue()


class ChangelogTests(unittest.TestCase):
    def test_section_stops_at_next_heading_and_empty_or_missing_is_none(self):
        body = changelog.section(LOG, "2026.10.6")
        self.assertIn("### Fixed", body)
        self.assertNotIn("Older note", body)
        self.assertEqual(changelog.section(LOG, "2026.10.5"), "- Older note.")
        self.assertIsNone(changelog.section(LOG, "2026.10.4"))
        self.assertIsNone(changelog.section(LOG, "1.0.0"))

    def test_html_escapes_and_renders_inline_runs(self):
        html = changelog.to_html(changelog.section(LOG, "2026.10.6"))
        self.assertIn("<h3>Fixed</h3>", html)
        self.assertIn("<code>a_b</code>", html)
        self.assertIn("&amp; <strong>bold</strong>", html)
        self.assertIn('<a href="https://github.com/Se7enbrc/glimmer/blob/main/docs/SECURITY.md">guide</a>', html)
        self.assertIn("&lt;app&gt;", html)
        self.assertIn("continued <em>here</em>.</li></ul>", html)
        self.assertIn("<p>Plain <em>tail</em> line.</p>", html)

    def test_markup_cannot_inject_and_entities_are_not_double_escaped(self):
        html = changelog.to_html("<script>x</script> &lt;ok&gt; &#169; a & b")
        self.assertNotIn("<script>", html)
        self.assertIn("&lt;script&gt;", html)
        self.assertIn("&lt;ok&gt; &#169; a &amp; b", html)

    def test_absolute_and_anchor_links_are_left_alone(self):
        html = changelog.to_html("[a](https://x.test/p) [b](#top) [c](mailto:m@x.test) [d](./docs/a.md)", "BASE/")
        for href in ("https://x.test/p", "#top", "mailto:m@x.test", "BASE/docs/a.md"):
            self.assertIn(f'href="{href}"', html)

    def test_main_formats_and_missing_version_exit_codes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "CHANGELOG.md"
            path.write_text(LOG)
            code, out, _ = run_main(changelog, ["--version", "2026.10.5", "--changelog", str(path)])
            self.assertEqual((code, out), (0, "- Older note.\n"))
            code, out, _ = run_main(changelog, ["--version", "2026.10.5", "--changelog", str(path),
                                                "--format", "html"])
            self.assertEqual(out, "<ul><li>Older note.</li></ul>\n")
            code, out, err = run_main(changelog, ["--version", "9.9.9", "--changelog", str(path)])
            self.assertEqual((code, out), (1, ""))
            self.assertIn("no '## 9.9.9' section", err)
            self.assertEqual(run_main(changelog, ["--version", "9.9.9", "--changelog", str(path), "--optional"]),
                             (0, "", ""))
        self.assertTrue(changelog.default_path().endswith("CHANGELOG.md"))


FEED = f"""<?xml version='1.0' encoding='utf-8'?>
<rss xmlns:sparkle="{SPARKLE}" version="2.0"><channel><title>Glimmer</title>
<item><title>2026.10.5</title><sparkle:version>20261008</sparkle:version>
<sparkle:shortVersionString>2026.10.5</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
<enclosure url="https://x.test/old.zip" sparkle:edSignature="oldsig" length="10"/></item>
<item><title>2026.10.4</title><sparkle:version>20261007</sparkle:version>
<sparkle:shortVersionString>2026.10.4</sparkle:shortVersionString>
<description>kept ]]&gt; text</description>
<enclosure url="https://x.test/older.zip" sparkle:edSignature="s" length="9"/></item>
</channel></rss>
"""
NEW = ["--short-version", "2026.10.6", "--version", "20261009", "--url", "https://x.test/new.zip",
       "--ed-signature", "newsig", "--length", "11"]
RETRY = ["--short-version", "2026.10.5", "--version", "20261008", "--url", "https://x.test/old.zip",
         "--ed-signature", "oldsig", "--length", "10"]


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)
        self.feed = self.dir / "appcast.xml"
        self.feed.write_text(FEED)
        (self.dir / "CHANGELOG.md").write_text(LOG)
        self.addCleanup(self.temp.cleanup)

    def run_feed(self, *args):
        return run_main(APPCAST, [str(self.feed), *args])

    def items(self):
        return ET.parse(self.feed).getroot().find("channel").findall("item")

    def test_insert_goes_first_with_cdata_notes_and_keeps_published_items(self):
        code, _, _ = self.run_feed(*NEW, "--channel", "rc", "--title", "RC 6", "--release-notes-url", "https://n.test")
        self.assertEqual(code, 0)
        items = self.items()
        self.assertEqual([i.findtext("title") for i in items], ["RC 6", "2026.10.5", "2026.10.4"])
        new = items[0]
        self.assertEqual(new.findtext(f"{{{SPARKLE}}}channel"), "rc")
        self.assertEqual(new.findtext(f"{{{SPARKLE}}}releaseNotesLink"), "https://n.test")
        self.assertEqual(new.find("enclosure").get(f"{{{SPARKLE}}}edSignature"), "newsig")
        self.assertIn("<![CDATA[", self.feed.read_text())
        self.assertIn("<strong>bold</strong>", new.findtext("description"))
        self.assertIn("kept ]]> text", items[2].findtext("description"))
        self.assertTrue(self.feed.read_text().endswith("\n"))

    def test_cdata_terminator_in_notes_is_split_not_leaked(self):
        self.assertEqual(APPCAST._escape_cdata(APPCAST._CDATA + "a]]>b"), "<![CDATA[a]]]]><![CDATA[>b]]>")
        self.assertEqual(APPCAST._escape_cdata("a<b"), "a&lt;b")

    def test_missing_changelog_warns_and_item_has_no_description(self):
        (self.dir / "CHANGELOG.md").unlink()
        code, _, err = self.run_feed(*NEW)
        self.assertEqual(code, 0)
        self.assertIn("no changelog", err)
        self.assertIsNone(self.items()[0].find("description"))

    def test_missing_section_warns_but_still_publishes(self):
        (self.dir / "CHANGELOG.md").write_text("## 1.0.0\n\n- x\n")
        _, _, err = self.run_feed(*NEW)
        self.assertIn("no '## 2026.10.6' CHANGELOG section", err)
        self.assertEqual(len(self.items()), 3)

    def test_argument_combinations_are_refused_before_touching_the_file(self):
        for args in ([], ["--short-version", "2026.10.6"], [*NEW, "--promote", "--channel", "rc"],
                     [*NEW, "--promote", "--backfill"], ["--channel", "rc", "--backfill"],
                     ["--title", "t", "--backfill"], ["--promote"]):
            with self.subTest(args=args):
                self.assertEqual(self.run_feed(*args)[0], 2)
                self.assertEqual(self.feed.read_text(), FEED)

    def test_feed_without_channel_is_an_error(self):
        self.feed.write_text("<rss/>")
        code, _, err = self.run_feed(*NEW)
        self.assertEqual(code, 1)
        self.assertIn("no <channel>", err)

    def test_published_enclosure_and_minimum_system_are_immutable(self):
        for change in (["--url", "https://x.test/evil.zip"], ["--ed-signature", "evil"], ["--length", "99"],
                       ["--min-system", "27.0"]):
            with self.subTest(change=change):
                self.assertEqual(self.run_feed(*RETRY, *change)[0], 2)
                self.assertEqual(self.feed.read_text(), FEED)
        code, out, _ = self.run_feed(*RETRY)
        self.assertEqual((code, out), (0, "  = appcast already current\n"))
        self.assertEqual(self.feed.read_text(), FEED)

    def test_reused_or_regressing_build_is_refused(self):
        self.assertEqual(self.run_feed("--short-version", "2026.10.6", "--version", "20261008", *NEW[4:])[0], 2)
        self.assertEqual(self.run_feed("--short-version", "2026.10.6", "--version", "20261001", *NEW[4:])[0], 2)
        self.assertEqual(self.feed.read_text(), FEED)

    def test_promote_moves_candidate_to_stable_in_place(self):
        self.run_feed(*NEW, "--channel", "rc")
        self.assertEqual(self.items()[0].findtext(f"{{{SPARKLE}}}channel"), "rc")
        code, out, _ = self.run_feed(*NEW, "--promote")
        self.assertEqual(code, 0)
        self.assertIn("promoted 2026.10.6", out)
        first = self.items()[0]
        self.assertIsNone(first.find(f"{{{SPARKLE}}}channel"))
        self.assertEqual(first.findtext("title"), "2026.10.6")
        self.assertEqual(len(self.items()), 3)

    def test_promote_requires_existing_candidate_with_identical_bytes(self):
        self.assertEqual(self.run_feed(*NEW, "--promote")[0], 2)
        self.run_feed(*NEW, "--channel", "rc")
        self.assertEqual(self.run_feed(*NEW[:-1], "12", "--promote")[0], 2)
        self.assertIsNotNone(self.items()[0].find(f"{{{SPARKLE}}}channel"))

    def test_dry_run_prints_and_never_writes(self):
        code, out, _ = self.run_feed(*NEW, "--dry-run")
        self.assertEqual(code, 0)
        self.assertIn("newsig", out)
        self.assertEqual(self.feed.read_text(), FEED)
        _, out, _ = self.run_feed(*RETRY, "--dry-run")
        self.assertEqual(out, FEED)

    def test_backfill_adds_only_missing_descriptions(self):
        _, _, err = self.run_feed("--backfill", "--dry-run")
        self.assertIn("backfilled 1", err)
        code, out, _ = self.run_feed("--backfill")
        self.assertEqual(code, 0)
        self.assertIn("backfilled 1", out)
        items = self.items()
        self.assertEqual(items[0].findtext("description").strip(), "<ul><li>Older note.</li></ul>")
        self.assertIn("kept ]]> text", items[1].findtext("description"))
        self.assertEqual(items[0].find("enclosure").get("url"), "https://x.test/old.zip")
        self.assertIn("backfilled 0", self.run_feed("--backfill")[1])

    def test_set_description_replaces_existing_after_title(self):
        item = ET.fromstring("<item><title>t</title><description>old</description><x/></item>")
        APPCAST.set_description(item, "new")
        self.assertEqual([c.tag for c in item], ["title", "description", "x"])
        self.assertEqual(item.findtext("description"), "new")
        bare = ET.fromstring("<item><x/></item>")
        APPCAST.set_description(bare, "d")
        self.assertEqual(bare[0].tag, "description")


DB = """# Windows
win,line
# Mac OS X
030000,Pad A,a:b0,platform:Mac OS X

#skipped,comment
030001,Pad B,a:b1,platform:Mac OS X
# Linux
linux,line
"""


class GameControllerDbTests(unittest.TestCase):
    def test_only_the_macos_section_is_kept(self):
        self.assertEqual(GAMEDB.macos_entries(DB),
                         ["030000,Pad A,a:b0,platform:Mac OS X", "030001,Pad B,a:b1,platform:Mac OS X"])

    def test_load_reads_a_local_file_and_fetches_urls(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "db.txt"
            path.write_text(DB)
            self.assertEqual(GAMEDB.load(str(path)), DB)
        response = patch.object(GAMEDB.urllib.request, "urlopen")
        with response as opened:
            opened.return_value.__enter__.return_value.read.return_value = b"remote"
            self.assertEqual(GAMEDB.load("https://x.test/db.txt"), "remote")
        opened.assert_called_once_with("https://x.test/db.txt")

    def write(self, text):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        source = root / "db.txt"
        source.write_text(text)
        out = root / "a/b/c/Data.swift"
        out.parent.mkdir(parents=True)
        return source, out

    def test_main_writes_swift_with_every_entry_and_a_correct_count(self):
        source, out = self.write("# Mac OS X\none\ntwo\n# Linux\n")
        with patch.object(GAMEDB, "OUT", out):
            code, stdout, _ = run_main(GAMEDB, [str(source)])
        self.assertEqual(code, 0)
        text = out.read_text()
        self.assertIn('        "one",\n        "two"\n    ]', text)
        self.assertIn("/// 2 SDL2-format mapping lines", text)
        self.assertIn("with 2 entries", stdout)

    def test_missing_section_and_unescapable_entries_abort_without_output(self):
        for text, message in (("# Linux\nx\n", "no Mac OS X entries"),
                              ('# Mac OS X\nbad"quote\n', "unexpected quote"),
                              ("# Mac OS X\nback\\slash\n", "unexpected quote")):
            with self.subTest(message=message):
                source, out = self.write(text)
                with patch.object(GAMEDB, "OUT", out):
                    code, _, _ = run_main(GAMEDB, [str(source)])
                self.assertIn(message, str(code))
                self.assertFalse(out.exists())


if __name__ == "__main__":
    unittest.main()
