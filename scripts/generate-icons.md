# `generate-icons.swift` - design notes

**What actually ships is not this.** The app icon is `Glimmer/AppIcon.icon`, a
hand-authored Icon Composer bundle: one `eclipse-mark.png` layer over a
violet-to-black vertical gradient declared in `icon.json`, with a slightly
brighter dark specialization. There is no `AppIcon.appiconset` in
`Assets.xcassets` any more. `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` plus
`CFBundleIconName` in `Info.plist` is what resolves it.

`generate-icons.swift` is the generator for the previous moon-and-sparkles
design. It still runs, and the rationale below is worth keeping because the
constraints it solved (the small-size collapse, the `.icon` bundle's placement)
apply to any replacement. Treat it as reference, not as the build step.

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
| _(none)_    | Light variant - legacy `.appiconset` output                                                                                                                                                                               |
| `--dark`    | Dark variant - brighter palette so the icon pops on a dark Dock                                                                                                                                                           |
| `--layered` | The layered 1024px PNGs into `AppIcon.icon/Assets` (`Background-Light.png` + `Background-Dark.png` + `Foreground.png`) consumed by macOS 26's Icon Composer bundle for light/dark/tinted/clear theme-snapping in the Dock |

In legacy mode the dark variant emits filenames with a `-dark` suffix, and the
`.appiconset`'s `Contents.json` carries both sets with
`appearances: [{luminosity: dark}]` entries pointing at the dark files. That
output directory no longer exists in the tree; on macOS 26 the Tahoe `.icon`
bundle is what the Dock reads.

## `.icon` bundle layout (`--layered`)

The Tahoe Icon Composer bundle splits the design into a flat canvas fill
(`icon.json`'s top-level `fill`, with a dark `fill-specialization` so the system
crossfades it on Appearance toggle) plus raster layers that theme-snap for
light/dark/tinted/clear. The two raster layers are rendered at 1024×1024 with NO
squircle clip - Tahoe applies the mask itself (squircle on macOS, circle on
watchOS, none on clear):

- **Background overlay** (`renderBackgroundOverlay`): the atmospheric glows +
  rim. The base indigo→violet gradient is deliberately NOT drawn here - that's
  `icon.json`'s top-level `fill`; this layer is just the depth glows on top.
- **Foreground** (`renderForeground`): the moon + sparkles, drawn with the LIGHT
  palette's moon/sparkle colors (warm cream + cool-white) which read fine on
  either appearance - the system's Liquid Glass shader handles the tinted/clear
  adaptations.

The `.icon` bundle lives next to `Assets.xcassets`, NOT inside it - Xcode 26
requires the Icon Composer bundle to be a top-level resource in the target so it
produces appearance-themed AppIcon entries in `Assets.car`. Placed inside
`.xcassets` the bundle is silently ignored. `generate-icons.swift --layered`
writes to the correct `Glimmer/AppIcon.icon/Assets`; the older
`generate-icon-layers.swift` still targets the inside-`.xcassets` path and is
superseded.

## Palette

Instance-based so light + dark variants can be swapped at CLI time.

- **Light**: midnight indigo → violet base.
- **Dark**: brighter, more saturated purple to stand out against the macOS dark
  Dock; bottom-right pulls the brand accent `#8110FE` directly so the icon
  thematically pairs with the in-app accent. The moon/sparkle palette is
  unchanged - cream-warm reads cleanly on either base. The dark moon-shade picks
  up the new background so the lit-from-upper-left illusion stays consistent
  with the surrounding gradient. The dark small-renderer background is a
  mid-bright violet that holds the silhouette at 16/32pt without becoming a neon
  flat fill.

## Small-size render

At 16pt / 32pt the full design (gradient bg, multiple sparkles, glass moon,
inner shadow, rim highlight) collapses into a purple smudge - the moon
silhouette is lost and the inner shadow eats most of what's left. The Dock /
Finder list / status menu all hit this path. Apple's first-party utilities solve
this with a dedicated low-res pass: drop secondary detail, push the primary mark
to ~50% canvas, flat fill, single-pixel-aware stroke (see Finder, Disk Utility,
Activity Monitor at 16pt). Anything ≤64px takes that branch; larger sizes use
the full design, which holds together fine.
