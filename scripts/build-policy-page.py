# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Render the canonical privacy document into the static Pages template."""

from html import escape
from pathlib import Path
import re

from changelog import to_html


ROOT = Path(__file__).resolve().parents[1]
LINK_BASE = "https://github.com/Se7enbrc/glimmer/blob/main/docs/"
MARKER = "{{POLICY_CONTENT}}"


def render_policy(source: str) -> str:
    if source.startswith("---\n"):
        _, separator, source = source[4:].partition("\n---\n")
        if not separator:
            raise ValueError("Unclosed policy front matter")
    source = source.strip()
    if not source.startswith("# ") or len(re.findall(r"^# ", source, re.M)) != 1:
        raise ValueError("The policy must start with one title")
    # Reuse the release renderer's paragraphs, flat bullets and inline markup.
    # Fail on unsupported blocks so a documentation edit cannot silently break Pages.
    if re.search(r"^[ \t]*(?:\||\{%|```|~~~|>|\d+\. |###|<)|^[ \t]+[-*] ", source, re.M):
        raise ValueError("Use headings, paragraphs and flat bullet lists in the policy")
    parts = re.split(r"^(#{1,2}) (.+)\n", source, flags=re.M)
    rendered = []
    for level, title, body in zip(parts[1::3], parts[2::3], parts[3::3]):
        content = to_html(body.strip(), LINK_BASE)
        if level == "#":
            content = content.replace("<p>", '<p class="policy-lead">', 1)
            rendered.append(f"<h1>{escape(title)}</h1>\n{content}")
        else:
            anchor = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
            rendered.append(
                f'<section aria-labelledby="{anchor}">\n'
                f'<h2 id="{anchor}">{escape(title)}</h2>\n{content}\n</section>'
            )
    return "\n".join(rendered)


def build(root: Path = ROOT) -> Path:
    template = (root / "website/privacy.html").read_text(encoding="utf-8")
    if template.count(MARKER) != 1:
        raise ValueError("The privacy template must contain one policy marker")
    content = render_policy((root / "docs/PRIVACY.md").read_text(encoding="utf-8"))
    output = root / "privacy/index.html"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(template.replace(MARKER, content), encoding="utf-8")
    return output


if __name__ == "__main__":
    build()
