# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Privacy page generation stays tied to the canonical document, offline."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("policy_page", SCRIPTS / "build-policy-page.py")
policy_page = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy_page)


class PolicyPageTests(unittest.TestCase):
    def test_renders_document_structure_and_resolves_document_links(self):
        source = """---
description: Not page content
---

# Privacy policy

Your PC & your choices.

## Local diagnostics

- Read [security](SECURITY.md#network-paths).
- Review `~/Library/Logs/Glimmer/`.

Email [support](mailto:glimmer-prerelease@ugfugl.io).
"""
        html = policy_page.render_policy(source)
        self.assertNotIn("description:", html)
        self.assertIn('<h1>Privacy policy</h1>', html)
        self.assertIn('Your PC &amp; your choices.', html)
        self.assertIn('<section aria-labelledby="local-diagnostics">', html)
        self.assertIn('<h2 id="local-diagnostics">Local diagnostics</h2>', html)
        self.assertIn('<ul><li>Read <a href="' + policy_page.LINK_BASE
                      + 'SECURITY.md#network-paths">security</a>.', html)
        self.assertIn('<code>~/Library/Logs/Glimmer/</code>', html)
        self.assertIn('href="mailto:glimmer-prerelease@ugfugl.io"', html)

    def test_rebuilding_reflects_source_edits_without_editing_template(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "docs").mkdir()
            (root / "website").mkdir()
            template = '<main>{{POLICY_CONTENT}}</main>'
            (root / "website/privacy.html").write_text(template)
            source = root / "docs/PRIVACY.md"
            for sentence in ("Original policy.", "Revised policy."):
                source.write_text(f"# Privacy policy\n\n{sentence}\n")
                html = policy_page.build(root).read_text()
                self.assertIn(sentence, html)
                self.assertNotIn(policy_page.MARKER, html)
            self.assertNotIn("Original policy.", html)
            self.assertEqual((root / "website/privacy.html").read_text(), template)

    def test_rejects_unsupported_blocks_and_missing_template_marker(self):
        for block in ("| Table |", '{% hint style="info" %}', "1. Step", "```text",
                      "### Nested heading", "<script>", "  - Nested bullet"):
            with self.subTest(block=block), self.assertRaises(ValueError):
                policy_page.render_policy("# Privacy policy\n\n" + block + "\n")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "website").mkdir()
            (root / "website/privacy.html").write_text("<main></main>")
            with self.assertRaises(ValueError):
                policy_page.build(root)

    def test_repository_document_and_template_build_together(self):
        source = (SCRIPTS.parent / "docs/PRIVACY.md").read_text()
        html = policy_page.render_policy(source)
        self.assertEqual(html.count("<h1>"), 1)
        self.assertEqual(html.count("<h2 "), source.count("\n## "))
        self.assertIn('href="https://se7enbrc.github.io/glimmer/support/"', html)


if __name__ == "__main__":
    unittest.main()
