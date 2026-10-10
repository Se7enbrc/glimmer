---
version: 1
slug: "index-html"
primary_target: "index.html"
related_targets: ["website/site.css", "website/site.js"]
---

# GitHub Pages landing page

Mode: Persuade. Audience: people with a gaming PC and an Apple silicon Mac.
Primary action: Download for Mac, linking to the latest notarized release.
Homebrew stays behind a native disclosure with the complete tap, trust and
install command. CNAME, original assets and GitHub Pages remain unchanged.

## Direction contract

THESIS: The other room. Right here. Let visitors try the launcher before
installing Glimmer. The demo shows only Ready, Connecting and the launcher while
a stream is running with its window hidden.

OWN-WORLD: System typography, the final app icon, frosted glass and Eclipse
Violet actions. A static violet eclipse behind the replica gives the page depth.
Dark and warm light appearances follow the system preference.

STORY: Understand PC-to-Mac streaming, download or try the launcher, then see
three claims: fidelity, native Mac integration and privacy. A short Mac-side
summary leads to the PC setup guide. OpenSSF evidence stays in the footer. Copy
is plain and specific; the replica needs no promotional invitation.

FIRST VIEWPORT: Logo and navigation, headline and download, then the replica at
70% of the desktop content width. The hero, replica and three claims fit at 1280
× 800 and 1440 × 900 in every state. On mobile, only the page reflows. The 580 ×
224 launcher scales as one unit with unchanged internal geometry.

FORM: Static HTML, CSS and plain JavaScript. No framework, external fonts,
analytics, remote badges or requests needed to load the page. Proof links open
the existing OpenSSF Best Practices and Scorecard assessments.

## Shipping-source contract

- `Glimmer/ContentView.swift:242–266`: 532-point content, 24-point side margins,
  16-point vertical spacing and content-sized layout. The owner’s running-app
  reference establishes the 580 × 224 window and neutral disabled glass.
  Settings gear, PC chevron and traffic lights are visual details.
- `Glimmer/ContentView.swift:335–395`: PC glyph, title, six-point chevron gap,
  spec line and trailing chip. The PC name is the fictional “Den PC”.
- `Glimmer/ContentViewSubviews.swift:104–127`: 28-point icon frame, 20-point
  symbol, 12-point gaps, one-line headline, flexible space and exactly one
  trailing element. Tiles use 16-point horizontal padding and 60-point height.
  The trailing slot holds play, a small progress indicator or “Back to Stream”.
- `Glimmer/ContentViewSubviews.swift:112–123,142–149`: progress replaces play;
  “Back to Stream” uses subheadline semibold; other tiles disable and dim while
  a session exists. Names truncate before the trailing element can move.
- `Glimmer/ContentView+ReadinessChip.swift:38–42,168–190`: “Ready · 5 ms”,
  “Connecting to Den PC…” and “Streaming”, with green/orange dots and a route
  glyph only while ready. The connecting string originates in
  `Glimmer/AppModel+Streaming.swift:66`.
- `Glimmer/AppModel+Streaming+Config.swift:31–37` and
  `Glimmer/ContentViewSubviews.swift:185–192`: “4K · 240 Hz · HDR · 200 Mbps”.
  Values illustrate a configuration, not measured performance.
- `Glimmer/ContentView.swift:310–332`: “Last played 4 minutes ago” below the
  tiles. Reset leaves this illustrative timestamp unchanged.

Clicking either app shows Connecting, then Streaming after 1.1 seconds. Clicking
the selected app or pressing Escape during Connecting cancels it. Clicking “Back
to Stream” or the quiet external Reset returns the replica to Ready. That reset
is a website action; the app itself resumes its stream. There is no stream
scene, HUD, fullscreen transition, telemetry, toast or stream keyboard shortcut.
The original public screenshot stays linked. The owner’s temporary screenshot
and prompt are references, never site assets.

## Accessibility and verification

Tiles are real buttons with state-specific accessible names. State changes are
announced; focus stays on the selected tile and returns there from Reset. Motion
is limited to a 150 ms press response, disabled under reduced motion. The
progress glyph is static; there are no repeating animations or sequences.
Download, documentation, the public screenshot and Homebrew work without
JavaScript. The replica is explicitly captioned as interactive.

Review Ready in dark/light at 1440 and 375, plus Connecting and Streaming in
dark at 1440. Compare Streaming beside the owner’s screenshot at equal scale.
Check both app paths, single trailing-element visibility and right alignment,
click/Escape cancellation, timer cancellation, both reset paths, keyboard and
focus, reduced motion, 320–1920 geometry, Homebrew copying and no-JavaScript
fallback. Automated accessibility checks supplement visual inspection; they do
not replace a manual VoiceOver session. Keep the app’s version and release
process separate from this static website change.
