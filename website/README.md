# Publish the support and privacy pages

Edit `docs/PRIVACY.md` to change the privacy policy. It is the only policy text;
`website/privacy.html` supplies the site's navigation and styling.

1. Generate the page locally:

   ```sh
   python3 scripts/build-policy-page.py
   ```

2. Preview `privacy/index.html` through a local HTTP server at the repo root.

The Pages workflow runs the same command before uploading the site. The
generated `privacy/index.html` is ignored by Git and is published at
<https://se7enbrc.github.io/glimmer/privacy/>. Generation uses the existing
release Markdown renderer, with document headings added by the page builder.
Keep the policy to headings, paragraphs and flat bullet lists; unsupported
blocks fail the build. Relative document links resolve to `docs/` on the
repository's default branch.

`support/index.html` is a short directory at
<https://se7enbrc.github.io/glimmer/support/>. Troubleshooting and reporting
steps stay in `docs/guides/TROUBLESHOOTING.md`; update, beta and contact
instructions stay in `docs/UPDATES.md`. Edit those guides instead of copying
their instructions into the site or App Store preparation pack.

Next: [read the privacy source](../docs/PRIVACY.md).
