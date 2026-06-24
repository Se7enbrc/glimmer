#!/usr/bin/env python3
"""Insert or replace a single <item> in a Sparkle appcast.xml.

Usage:
  update-appcast.py <appcast.xml> \
      --short-version 2026.6.4 --version 20260613 \
      --url https://.../Glimmer-2026.6.4.zip \
      --ed-signature <sig> --length <bytes> \
      [--min-system 26.0] [--release-notes-url URL]

Idempotent on <sparkle:version> (the build number): an existing item with the
same build number is replaced, and the new item is inserted ahead of the others
(newest first). The file is written back in place.
"""
import argparse
import sys
import xml.etree.ElementTree as ET
from email.utils import formatdate

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")


def sk(tag: str) -> str:
    return f"{{{SPARKLE}}}{tag}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("appcast")
    ap.add_argument("--short-version", required=True)
    ap.add_argument("--version", required=True, help="build number (CFBundleVersion)")
    ap.add_argument("--url", required=True)
    ap.add_argument("--ed-signature", required=True)
    ap.add_argument("--length", required=True)
    ap.add_argument("--min-system", default="26.0")
    ap.add_argument("--release-notes-url", default=None)
    a = ap.parse_args()

    tree = ET.parse(a.appcast)
    channel = tree.getroot().find("channel")
    if channel is None:
        print("ERR: no <channel> in appcast", file=sys.stderr)
        sys.exit(1)

    # Drop any existing item with the same build number (re-publish / re-sign).
    for item in channel.findall("item"):
        v = item.find(sk("version"))
        if v is not None and v.text == a.version:
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = a.short_version
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

    ET.indent(tree, space="  ")
    tree.write(a.appcast, encoding="utf-8", xml_declaration=True)
    print(f"  ✓ appcast item {a.short_version} ({a.version})")


if __name__ == "__main__":
    main()
