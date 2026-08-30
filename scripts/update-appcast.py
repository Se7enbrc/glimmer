#!/usr/bin/env python3
"""Insert or replace a single <item> in a Sparkle appcast.xml.

Usage:
  update-appcast.py <appcast.xml> \
      --short-version 2026.6.4 --version 20260613 \
      --url https://.../Glimmer-2026.6.4.zip \
      --ed-signature <sig> --length <bytes> \
      [--min-system 26.0] [--release-notes-url URL] [--changelog PATH]

  update-appcast.py <appcast.xml> --backfill [--dry-run]

Idempotent on <sparkle:version> (the build number): an existing item with the
same build number is replaced, and the new item is inserted ahead of the others
(newest first). The file is written back in place.

Each item carries that version's CHANGELOG.md section as HTML inside a CDATA
<description>, which is what Sparkle's update dialog shows as "what's new". A
version with no CHANGELOG section simply gets no description (Sparkle then
falls back to the release-notes link, or to nothing) rather than a placeholder.

--backfill adds descriptions to EXISTING items that lack one, touching nothing
else - so the notes land for users on older builds too. --dry-run prints the
result to stdout and leaves the file alone.
"""
import argparse
import os
import sys
import xml.etree.ElementTree as ET
from email.utils import formatdate

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import changelog  # noqa: E402  (sibling module, path set above)

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")

# ElementTree has no CDATA node. Sparkle renders <description> as HTML either
# way (escaped entities decode to the same markup), but CDATA is what the
# appcast format documents and what stays readable in the committed XML - so
# text tagged with this sentinel is emitted raw, wrapped in CDATA.
_CDATA = "\x00cdata\x00"
_escape_cdata_orig = getattr(ET, "_escape_cdata", None)


def _escape_cdata(text):  # type: ignore[no-untyped-def]
    if isinstance(text, str) and text.startswith(_CDATA):
        # `]]>` cannot appear inside a CDATA section; split it across two.
        return "<![CDATA[" + text[len(_CDATA) :].replace("]]>", "]]]]><![CDATA[>") + "]]>"
    return _escape_cdata_orig(text)


if _escape_cdata_orig is not None:
    ET._escape_cdata = _escape_cdata  # type: ignore[attr-defined]


def sk(tag: str) -> str:
    return f"{{{SPARKLE}}}{tag}"


def load_changelog(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def description_for(text: str, short_version: str) -> str | None:
    """The CDATA-tagged HTML for a version, or None if it has no section."""
    body = changelog.section(text, short_version)
    if body is None:
        return None
    return _CDATA + "\n" + changelog.to_html(body) + "\n"


def set_description(item: ET.Element, html_text: str) -> None:
    """Put <description> right after <title>, replacing any existing one."""
    for old in item.findall("description"):
        item.remove(old)
    desc = ET.Element("description")
    desc.text = html_text
    children = list(item)
    at = 1 if children and children[0].tag == "title" else 0
    item.insert(at, desc)


def retag_descriptions(channel: ET.Element) -> None:
    """Re-tag descriptions read back from disk so they round-trip as CDATA.

    Parsing collapses a CDATA section to plain text; without this, every
    re-run would rewrite already-published descriptions as escaped HTML and
    churn the whole file.
    """
    for item in channel.findall("item"):
        for desc in item.findall("description"):
            if desc.text and not desc.text.startswith(_CDATA):
                desc.text = _CDATA + desc.text


def backfill(channel: ET.Element, text: str) -> int:
    """Add descriptions to items that lack one and have a CHANGELOG section."""
    added = 0
    for item in channel.findall("item"):
        if item.find("description") is not None:
            continue
        sv = item.find(sk("shortVersionString"))
        title = item.find("title")
        version = (sv.text if sv is not None else None) or (title.text if title is not None else None)
        if not version:
            continue
        html_text = description_for(text, version.strip())
        if html_text is None:
            continue
        set_description(item, html_text)
        added += 1
    return added


def write(tree: ET.ElementTree, path: str, dry_run: bool) -> None:
    ET.indent(tree, space="  ")
    if dry_run:
        out = ET.tostring(tree.getroot(), encoding="unicode", xml_declaration=True)
        sys.stdout.write(out + "\n")
        return
    tree.write(path, encoding="utf-8", xml_declaration=True)
    # ET.write leaves no trailing newline; add one so pre-commit's end-of-file-fixer
    # doesn't reformat the file and abort the publish commit.
    with open(path, "a", encoding="utf-8") as f:
        f.write("\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("appcast")
    ap.add_argument("--short-version")
    ap.add_argument("--version", help="build number (CFBundleVersion)")
    ap.add_argument("--url")
    ap.add_argument("--ed-signature")
    ap.add_argument("--length")
    ap.add_argument("--min-system", default="26.0")
    ap.add_argument("--release-notes-url", default=None)
    ap.add_argument("--changelog", default=None, help="path to CHANGELOG.md")
    ap.add_argument("--backfill", action="store_true", help="also fill in descriptions on existing items")
    ap.add_argument("--dry-run", action="store_true", help="print the result to stdout; do not write")
    a = ap.parse_args()

    insert = a.short_version is not None
    if insert:
        missing = [n for n in ("version", "url", "ed_signature", "length") if getattr(a, n) is None]
        if missing:
            ap.error("--short-version requires " + ", ".join("--" + m.replace("_", "-") for m in missing))
    elif not a.backfill:
        ap.error("give either the item arguments (--short-version ...) or --backfill")

    cl_path = a.changelog or os.path.join(os.path.dirname(os.path.abspath(a.appcast)), "CHANGELOG.md")
    cl_text = load_changelog(cl_path) if os.path.exists(cl_path) else ""
    if not cl_text:
        print(f"  ! no changelog at {cl_path} - items will carry no release notes", file=sys.stderr)

    tree = ET.parse(a.appcast)
    channel = tree.getroot().find("channel")
    if channel is None:
        print("ERR: no <channel> in appcast", file=sys.stderr)
        sys.exit(1)
    retag_descriptions(channel)

    if insert:
        # Drop any existing item with the same build number (re-publish / re-sign).
        for item in channel.findall("item"):
            v = item.find(sk("version"))
            if v is not None and v.text == a.version:
                channel.remove(item)

        item = ET.Element("item")
        ET.SubElement(item, "title").text = a.short_version
        html_text = description_for(cl_text, a.short_version) if cl_text else None
        if html_text is not None:
            ET.SubElement(item, "description").text = html_text
        else:
            print(f"  ! no '## {a.short_version}' CHANGELOG section - item has no release notes", file=sys.stderr)
        # UTC, not localtime: the appcast is public-by-design, and a local timezone
        # offset (e.g. -0400) is a free geolocation signal on a pseudonymous project.
        ET.SubElement(item, "pubDate").text = formatdate(usegmt=True)
        ET.SubElement(item, sk("version")).text = a.version
        ET.SubElement(item, sk("shortVersionString")).text = a.short_version
        ET.SubElement(item, sk("minimumSystemVersion")).text = a.min_system
        if a.release_notes_url:
            ET.SubElement(item, sk("releaseNotesLink")).text = a.release_notes_url
        enc = ET.SubElement(item, "enclosure")
        enc.set("url", a.url)
        enc.set("type", "application/octet-stream")
        enc.set(sk("edSignature"), a.ed_signature)
        enc.set("length", a.length)

        # Insert ahead of the first existing <item> (newest first), after the
        # channel's metadata elements.
        insert_at = len(list(channel))
        for i, child in enumerate(list(channel)):
            if child.tag == "item":
                insert_at = i
                break
        channel.insert(insert_at, item)

    filled = backfill(channel, cl_text) if (a.backfill and cl_text) else 0

    write(tree, a.appcast, a.dry_run)
    if insert:
        print(f"  ✓ appcast item {a.short_version} ({a.version})", file=sys.stderr if a.dry_run else sys.stdout)
    if a.backfill:
        print(f"  ✓ backfilled {filled} description(s)", file=sys.stderr if a.dry_run else sys.stdout)


if __name__ == "__main__":
    main()
