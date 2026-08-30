#!/usr/bin/env python3
"""Extract one version's section out of CHANGELOG.md, as Markdown or as HTML.

CHANGELOG.md is the single source of truth for "what's new": this module turns
one `## <version> - <date>` section into the two forms the release pipeline
needs - Markdown for the GitHub release body, and HTML for the Sparkle appcast
`<description>` (Sparkle renders it in a WebView).

Usage:
  changelog.py --version 2026.8.14 [--format html|markdown] [--changelog PATH]
               [--optional]

Exits 1 if the version has no section, unless --optional is given (then it
prints nothing and exits 0, so a caller can fall back to boilerplate).

Importable: `section(text, version)`, `to_html(markdown)`.
"""

import argparse
import os
import re
import sys

# Relative links in the changelog (docs/SECURITY.md) resolve against the repo on
# GitHub; inside Sparkle's WebView there is nothing to resolve them against, so
# they are absolutized on the way out.
LINK_BASE = "https://github.com/Se7enbrc/glimmer/blob/main/"

# The prose is hand-written Markdown; only the constructs the changelog
# actually uses are supported (h3, flat bullet lists, paragraphs, and the
# inline run of link / code / bold / italic). Anything else passes through as
# escaped text rather than being silently mangled.
_HEADING = re.compile(r"^##\s+(\S+)\s*(?:-.*)?$")
_SUBHEAD = re.compile(r"^###\s+(.*)$")
_BULLET = re.compile(r"^[-*]\s+(.*)$")
# `&` that does not already start a character entity - so `&lt;app&gt;` written
# in the changelog stays a literal `<app>` instead of double-escaping.
_BARE_AMP = re.compile(r"&(?!(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#[xX][0-9A-Fa-f]+);)")
_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
_CODE = re.compile(r"`([^`]+)`")
_BOLD = re.compile(r"\*\*([^*]+)\*\*")
_ITALIC = re.compile(r"(?<![\w*])[_*]([^_*\n]+)[_*](?![\w*])")


def section(text: str, version: str) -> str | None:
    """Return the body of `## <version> ...`, or None if there is no such section."""
    out: list[str] = []
    collecting = False
    for line in text.splitlines():
        m = _HEADING.match(line)
        if m:
            if collecting:
                break
            collecting = m.group(1) == version
            continue
        if collecting:
            out.append(line)
    if not collecting and not out:
        return None
    body = "\n".join(out).strip("\n")
    return body if body.strip() else None


def _escape(s: str) -> str:
    return _BARE_AMP.sub("&amp;", s).replace("<", "&lt;").replace(">", "&gt;")


def _inline(s: str, link_base: str) -> str:
    """Escape, then apply the inline Markdown run. Code spans are held out of
    the later passes so a `_` or `*` inside `code` is not read as emphasis."""
    held: list[str] = []

    def hold(m: re.Match[str]) -> str:
        held.append(f"<code>{_escape(m.group(1))}</code>")
        return f"\x00{len(held) - 1}\x00"

    def link(m: re.Match[str]) -> str:
        href = m.group(2)
        if "://" not in href and not href.startswith(("#", "mailto:")):
            href = link_base + href.lstrip("./")
        return f'<a href="{_escape(href)}">{m.group(1)}</a>'

    s = _CODE.sub(hold, s)
    s = _escape(s)
    s = _LINK.sub(link, s)
    s = _BOLD.sub(lambda m: f"<strong>{m.group(1)}</strong>", s)
    s = _ITALIC.sub(lambda m: f"<em>{m.group(1)}</em>", s)
    return re.sub(r"\x00(\d+)\x00", lambda m: held[int(m.group(1))], s)


def to_html(markdown: str, link_base: str = LINK_BASE) -> str:
    """Convert a changelog section to the simple HTML Sparkle shows in its WebView."""
    out: list[str] = []
    para: list[str] = []
    items: list[list[str]] = []

    def flush_para() -> None:
        if para:
            out.append(f"<p>{_inline(' '.join(para), link_base)}</p>")
            para.clear()

    def flush_list() -> None:
        if items:
            body = "".join(f"<li>{_inline(' '.join(i), link_base)}</li>" for i in items)
            out.append(f"<ul>{body}</ul>")
            items.clear()

    for raw in markdown.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped:
            flush_para()
            # A blank line does not end a list: the changelog uses loose lists
            # whose items are separated by blank lines. A non-bullet line does.
            continue
        if sub := _SUBHEAD.match(stripped):
            flush_para()
            flush_list()
            out.append(f"<h3>{_inline(sub.group(1), link_base)}</h3>")
            continue
        if bullet := _BULLET.match(stripped):
            flush_para()
            items.append([bullet.group(1)])
            continue
        if items and line[:1] in (" ", "\t"):
            # Indented continuation of the current bullet.
            items[-1].append(stripped)
            continue
        flush_list()
        para.append(stripped)

    flush_para()
    flush_list()
    return "\n".join(out)


def default_path() -> str:
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "CHANGELOG.md")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True, help="marketing version, e.g. 2026.8.14")
    ap.add_argument("--format", choices=("html", "markdown"), default="markdown")
    ap.add_argument("--changelog", default=None, help="path to CHANGELOG.md")
    ap.add_argument("--optional", action="store_true", help="print nothing and exit 0 if absent")
    ap.add_argument("--link-base", default=LINK_BASE, help="base for relative links in --format html")
    a = ap.parse_args()

    path = a.changelog or default_path()
    with open(path, encoding="utf-8") as f:
        body = section(f.read(), a.version)

    if body is None:
        if a.optional:
            return
        print(f"ERR: no '## {a.version}' section in {path}", file=sys.stderr)
        sys.exit(1)

    print(to_html(body, a.link_base) if a.format == "html" else body)


if __name__ == "__main__":
    main()
