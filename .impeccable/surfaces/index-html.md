---
version: 1
slug: "index-html"
primary_target: "index.html"
related_targets: ["website/site.css", "website/site.js"]
---

# GitHub Pages landing page

Mode: Persuade. Audience: people with a gaming PC and an Apple Silicon Mac.
Primary action: download the released Mac app. Proof: the real launcher capture,
the committed feature documentation, and the source code. Use static HTML and
CSS, with JavaScript only for the Homebrew copy button.

## Direction contract

THESIS: Your gaming PC belongs on your Mac. A real, generous launcher capture
makes the native experience the evidence, with no invented performance numbers.

OWN-WORLD: Preserve the app's system typography, white and quiet gray surfaces,
Eclipse Violet actions, and final icon. The desktop product photograph carries
all decorative color. No new visual identity, assets, or dependencies.

STORY: Recognize the Mac app, see how it fits play and everyday Mac use, then
download and pair with Sunshine. Free software and requirements stay explicit.

FIRST VIEWPORT: A compact product masthead; a large two-line left-aligned
headline and right-side installation action; a full-width real launcher capture
underneath. On phones the text and action stack above the uncropped image.

FORM: Product showroom, following the existing visual system. A compact Homebrew
command that copies with an accessible confirmation and recovery text.

FINISH: Review desktop and mobile layouts in both appearances, test navigation
and copying, and document the result. Keep the source of every image clear.

Existing PNGs remain unchanged in docs/assets. The screenshot is a product
capture, not a latency guarantee. DESIGN.md remains the app's authority.

## Appearance and verification

The page follows system light and dark appearance automatically. Dark surfaces
use neutral charcoal, with the established night violet for primary actions;
links lighten on hover to preserve contrast. The authentic launcher image is
shared between appearances. No appearance toggle or external assets are needed.

The website scales system typography for a public page instead of borrowing the
app's compact control sizes. Semantics, native links and buttons, an ordered
setup list, a disclosure for Homebrew, visible keyboard focus and reduced-motion
support keep the surface usable without custom widgets. JavaScript enhances only
the copy button; the command and every navigation path work without it.

Verified in Arc: desktop light and dark, a 390px mobile viewport, complete page
captures, internal navigation, Homebrew disclosure and copy confirmation. Local
assets, fragment targets, unique IDs, JavaScript syntax and light/dark text
contrast passed. The existing PRODUCT.md, DESIGN.md and design sidecar are
preserved; web sizing and neutral surface values are scoped to this route.
