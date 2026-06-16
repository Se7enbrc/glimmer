# `generate-icons.swift` — design notes

Generates the Glimmer app icon set in Apple's macOS 26 "Liquid Glass" style.
This is the long-form rationale that used to live in the script header; the
script keeps only concise pointers so it stays under the SwiftLint file-length
guardrail. Behavior is unchanged — this is documentation only.

## Composition (back-to-front)

1. Midnight diagonal gradient background (indigo → violet) + warm corner accent
2. Frosted-glass moon body (radial gradient) with an inset shadow for depth and
   a soft crescent shading to give it a three-quarter-lit feel
3. Sparkles rendered as radial gradients with bright specular cores
4. Rim highlight along the top edge for the "lifted glass" feeling
5. Faint inner stroke around the squircle to define the tile edge

## Usage

Run via `swift scripts/generate-icons.swift [flag]`:

| Flag        | Output                                                                                                                                                                                                                    |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| _(none)_    | Light variant — legacy `.appiconset` output                                                                                                                                                                               |
| `--dark`    | Dark variant — brighter palette so the icon pops on a dark Dock                                                                                                                                                           |
| `--layered` | The layered 1024px PNGs into `AppIcon.icon/Assets` (`Background-Light.png` + `Background-Dark.png` + `Foreground.png`) consumed by macOS 26's Icon Composer bundle for light/dark/tinted/clear theme-snapping in the Dock |

In legacy mode the dark variant emits filenames with a `-dark` suffix; the
AppIcon `Contents.json` carries both sets, with
`appearances: [{luminosity: dark}]` entries pointing at the dark files. The
legacy `.appiconset` is kept so this script can still regenerate it, but on
macOS 26 the Tahoe `.icon` bundle is what the Dock reads (`CFBundleIconName`
resolves the `.icon`-derived asset first).

## `.icon` bundle layout (`--layered`)

The Tahoe Icon Composer bundle splits the design into a flat canvas fill
(`icon.json`'s top-level `fill`, with a dark `fill-specialization` so the system
crossfades it on Appearance toggle) plus raster layers that theme-snap for
light/dark/tinted/clear. The two raster layers are rendered at 1024×1024 with NO
squircle clip — Tahoe applies the mask itself (squircle on macOS, circle on
watchOS, none on clear):

- **Background overlay** (`renderBackgroundOverlay`): the atmospheric glows +
  rim. The base indigo→violet gradient is deliberately NOT drawn here — that's
  `icon.json`'s top-level `fill`; this layer is just the depth glows on top.
- **Foreground** (`renderForeground`): the moon + sparkles, drawn with the LIGHT
  palette's moon/sparkle colors (warm cream + cool-white) which read fine on
  either appearance — the system's Liquid Glass shader handles the tinted/clear
  adaptations.

The `.icon` bundle lives next to `Assets.xcassets`, NOT inside it — Xcode 26
requires the Icon Composer bundle to be a top-level resource in the target so it
produces appearance-themed AppIcon entries in `Assets.car`. (When placed inside
`.xcassets` the bundle is silently ignored.)

## Palette

Instance-based so light + dark variants can be swapped at CLI time.

- **Light**: midnight indigo → violet base.
- **Dark**: brighter, more saturated purple to stand out against the macOS dark
  Dock; bottom-right pulls the brand accent `#8110FE` directly so the icon
  thematically pairs with the in-app accent. The moon/sparkle palette is
  unchanged — cream-warm reads cleanly on either base. The dark moon-shade picks
  up the new background so the lit-from-upper-left illusion stays consistent
  with the surrounding gradient. The dark small-renderer background is a
  mid-bright violet that holds the silhouette at 16/32pt without becoming a neon
  flat fill.

## Small-size render

At 16pt / 32pt the full design (gradient bg, multiple sparkles, glass moon,
inner shadow, rim highlight) collapses into a purple smudge — the moon
silhouette is lost and the inner shadow eats most of what's left. The Dock /
Finder list / status menu all hit this path. Apple's first-party utilities solve
this with a dedicated low-res pass: drop secondary detail, push the primary mark
to ~50% canvas, flat fill, single-pixel-aware stroke (see Finder, Disk Utility,
Activity Monitor at 16pt). Anything ≤64px takes that branch; larger sizes use
the full design, which holds together fine.
