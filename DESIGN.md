---
name: Glimmer
description:
  A Mac-native Sunshine client that makes the PC in the other room feel plugged
  into the Mac.
colors:
  eclipse-violet: "#6B0F9E"
  eclipse-violet-night: "#A847E0"
  ready-green: "#28CD41"
  caution-orange: "#FF9500"
  fault-red: "#FF3B30"
  default-yellow: "#FFCC00"
  label: "#000000D9"
  secondary-label: "#00000080"
  tertiary-label: "#0000003F"
typography:
  display:
    fontFamily: "SF Pro Display, -apple-system, system-ui, sans-serif"
    fontSize: "26px"
    fontWeight: 700
    letterSpacing: "-0.4px"
  headline:
    fontFamily: "SF Pro Display, -apple-system, system-ui, sans-serif"
    fontSize: "17px"
    fontWeight: 600
  title:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 400
  body:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
  label:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 500
  caption:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "10px"
    fontWeight: 400
rounded:
  chip: "6px"
  control: "8px"
  tile: "10px"
  inset: "12px"
  pc-tile: "16px"
  card: "26px"
  capsule: "9999px"
spacing:
  hairline: "2px"
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
  margin: "60px"
components:
  stream-button:
    backgroundColor: "{colors.eclipse-violet}"
    textColor: "{colors.label}"
    typography: "{typography.headline}"
    rounded: "{rounded.capsule}"
    padding: "12px 22px"
    height: "46px"
  hero-card:
    backgroundColor: "{colors.eclipse-violet}"
    textColor: "{colors.label}"
    rounded: "{rounded.card}"
    padding: "16px"
    width: "460px"
  app-tile:
    textColor: "{colors.label}"
    typography: "{typography.label}"
    rounded: "{rounded.tile}"
    padding: "0 12px"
    height: "44px"
  readiness-chip:
    textColor: "{colors.label}"
    rounded: "{rounded.capsule}"
    padding: "4px 10px"
  pc-tile:
    textColor: "{colors.label}"
    rounded: "{rounded.pc-tile}"
    padding: "16px"
  hotkey-recorder:
    textColor: "{colors.label}"
    typography: "{typography.body}"
    rounded: "{rounded.capsule}"
    padding: "4px 12px"
    width: "80px"
    height: "22px"
  hotkey-recorder-recording:
    textColor: "{colors.eclipse-violet}"
  connect-banner:
    textColor: "{colors.label}"
    rounded: "{rounded.inset}"
    padding: "10px 14px"
  stream-ended-toast:
    textColor: "{colors.label}"
    typography: "{typography.label}"
    rounded: "{rounded.capsule}"
    padding: "8px 18px"
---

# Design System: Glimmer

## Overview

**Creative North Star: "The Other Room"**

The gaming PC lives in another room, and Glimmer is the doorway to it. The
interface is a quiet Mac surface that says one thing at a time: this PC is
ready, and here is the button that takes you there. Everything that isn't that
sentence belongs to macOS: its materials, its type, its controls, its menus. The
only thing Glimmer brings of its own is Eclipse Violet, the colour of the light
under the door.

Surfaces are tactile, but taste comes first. The things you can press feel like
objects: Liquid Glass that refracts what sits behind the window, a soft downward
shadow, a slight give when pressed (scale 0.985). Everything else stays flat:
facts, labels, explanations and status sit as plain text on the system material,
with no chrome. Depth marks what can be pressed or what floats above the window,
never decoration.

The launcher is compact and sized to its content. A window with empty space in
it reads as unfinished, so the card fills its width with a header row and a grid
of app tiles instead of a thin column floating in the middle. Two layouts have
been tried and rejected: a neutral grey card (the "grey blob") and a narrow
centred column in a wide card. The app icon is final and is not redrawn,
recoloured or reinterpreted.

**Key Characteristics:**

- One brand hue, Eclipse Violet, used at full strength only on the primary
  capsule button.
- Liquid Glass and soft black shadows only on things you can press or that
  float.
- SF system text styles throughout; footnote-size secondary text does the
  explaining.
- Continuous (squircle) corners, concentric from the card inward.
- Windows sized to their content; no empty space, no stretched columns.
- Motion is snappy and short, and every pulse or bounce respects Reduce Motion.

## Colors

One saturated violet over system materials, with the status colours that macOS
already uses.

### Primary

- **Eclipse Violet** (#6B0F9E light, oklch(41.7% 0.203 308)): the accent colour
  of the app (`AccentColor`). At full strength on the primary capsule button
  (Stream on the launcher, "Pair a PC…" in the empty state, the pair sheet's
  main action) and as the system tint on switches, focus rings and the pairing
  glyph. At half strength across the launcher's PC card, so the card belongs to
  the button without competing with it.
- **Eclipse Violet, night** (#A847E0 dark, oklch(59.5% 0.227 310)): the same
  accent in dark appearance, lifted so it reads against dark glass without
  glowing.

The accent surface is a diagonal gradient built from the accent itself
(top-leading to bottom-trailing): the accent lightened with 12% white at 55%
opacity, the accent at 38% in the middle, and the accent darkened with 25% black
at 45% opacity. The Stream button and the PC card share this one gradient and
differ only in strength.

### Neutral

- **Label** (#000000D9, white at 85% in dark): primary text: PC names, app
  names, button labels.
- **Secondary Label** (#00000080, white at 55% in dark): explanations, the spec
  line, trailing play glyphs, addresses.
- **Tertiary Label** (#0000003F, white at 25% in dark): the quietest facts, such
  as "Last played" on a PC tile.
- Backgrounds are system materials rather than colours: regular material on the
  launcher, thin material on Settings, sheets and the toast, quaternary fills
  for inset panels.

### Status

- **Ready Green** (#28CD41, system green): the ready dot on the readiness chip
  and in the menu bar panel, and a healthy controller battery.
- **Caution Orange** (#FF9500, system orange): the readiness dot while
  connecting or when the PC needs attention, and a low controller battery.
- **Fault Red** (#FF3B30, system red): the connect-failure banner's stroke and
  tint, and errors in the log viewer.
- **Default Yellow** (#FFCC00, system yellow): the star that marks the default
  PC.

### Named Rules

**The One Violet Rule.** Eclipse Violet is the only brand hue. There is no
secondary or tertiary accent, and violet never marks status.

**The Half-Strength Rule.** The PC card carries the accent at about half the
button's strength (gradient at 55% opacity, glass tint 0.12 against the button's
0.25). One primary capsule per screen is the only full-strength violet.

**The Dot, Not Fill Rule.** Status colours appear as a small dot (6 to 7pt), a
glyph or a line of text, never as a filled surface. The one exception is the
connect-failure banner: glass with a faint red tint (0.12) and a 1pt red stroke,
where the stroke carries the severity.

## Typography

**Display Font:** SF Pro Display (the system font) **Body Font:** SF Pro Text
(the system font) **Label/Mono Font:** SF Mono via `.monospaced()`, only for
addresses and key notation

**Character:** Only the system font, set with the built-in text styles, so that
Glimmer reads at the same sizes as Finder and System Settings and scales with
the user's text size.

### Hierarchy

- **Display** (bold 700, 26pt, tracking -0.4): the empty state's headline only
  ("Let's find your gaming PC").
- **Headline** (semibold 600, 17pt, the title2 style): the PC name on the
  launcher card and the Stream button's label.
- **Title** (regular 400, 15pt, the title3 style): the empty state's supporting
  line and the few section titles outside a Form.
- **Body** (regular 400, 13pt): Settings rows, menu items and form labels, via
  the system default.
- **Label** (medium 500, 12pt, the callout style): app tile names; the regular
  weight carries the spec line.
- **Caption** (regular 400, 10pt, the footnote and caption styles): the
  explanatory line under a toggle, the readiness chip (in medium weight), and
  the "Last played" line.

### Named Rules

**The System Voice Rule.** Use text styles, not point sizes. Fixed sizes are
allowed only for SF Symbol glyph sizing and the two display moments above.

**The Footnote Explains Rule.** An explanation sits in footnote-size secondary
text inside the control's own label, directly under its title, never as a loose
paragraph elsewhere in the pane.

## Layout

The launcher is a content-sized window: its column ends in
`.fixedSize(horizontal: false, vertical: true)`, and the window's minimum width
is 580pt. Inside it, the PC card is 460pt wide in 60pt side margins, with 16pt
of inset. The card has a header row (the device glyph, the PC name, a flexible
gap and the readiness chip on the trailing edge) and, below it, a two-column
grid of app tiles with 8pt gutters. The grid shows at most four cells; beyond
four apps, the fourth cell is a menu listing the rest. Under the card, in a
16pt-spaced column: the spec line, the Stream button (up to 380pt wide) and the
"Last played" footer. A failure banner, when there is one, sits above the card.
While connecting, the card grows to 104% with a snappy spring.

Settings is a standard split view (sidebar plus a grouped Form), with a minimum
size of 680 by 540pt. The menu bar panel is 300pt wide.

The spacing rhythm is 8pt: 8 and 10 are the everyday gaps, 16 and 20 separate
groups, and 2, 4 and 6 are fine steps inside a control.

### Named Rules

**The Sized-to-Content Rule.** Windows and cards are exactly as big as their
contents. No `minHeight` floor, no `maxWidth: .infinity` and no trailing
`Spacer` on the launcher column; prove a geometry change with the osascript
window check in CONTRIBUTING.

**The No Empty Aisles Rule.** A narrow column centred in a wide container reads
as wasted space. Fill the width with structure (a header row, a grid) or narrow
the container.

## Elevation & Depth

Glimmer is tactile but restrained, with depth reserved for surfaces that respond
to touch or float over the window. Liquid Glass (`.glassEffect`) is the primary
depth cue: interactive glass on the app tiles, accent-tinted glass on the PC
card and the Stream button, plain glass on the readiness chip and the PC tiles
in Settings. Glass siblings are grouped in one `GlassEffectContainer` whose
spacing matches the layout gap, so neighbours merge and refract as one surface.
The refraction and colour behind the glass come from the desktop showing
through, not from a gradient to remove. Shadows are black, soft and always cast
downward.

### Shadow Vocabulary

- **Card lift** (black 18%, radius 16, y 6): the launcher's PC card.
- **Button lift** (black 18%, radius 12, y 4): the Stream button.
- **Icon lift** (black 20%, radius 10, y 4): the app icon on the About pane.
- **Toast float** (black 12%, radius 8, y 4): the "Stream ended" toast.

### Named Rules

**The Press, Not Pose Rule.** Depth (glass, shadow or scale) marks something you
can press or something floating above the window. Facts and labels sit flat on
the material.

**The One Light Rule.** Every shadow is black, at 12 to 20% opacity, offset
downward. No coloured glows, no inner shadows, no upward light.

## Shapes

Every corner is continuous (a squircle), never circular. Radii nest: an inner
shape's radius is the outer radius minus the inset between them, so the 26pt
card with a 16pt inset holds 10pt tiles. Capsules mark a single action or a
single state (the Stream button, the readiness chip, the toast). Rounded
rectangles mark containers: 6pt for glyph chips in the sidebar and menu bar, 8pt
for small controls and badges, 10pt for app tiles, 12pt for inset panels, 16pt
for PC tiles and 26pt for the launcher card. Borders are hairline strokes at
0.5pt and low opacity, used only where material alone would disappear (the
Stream button's rim, the toast, the empty state's medallion). Heavier strokes
carry state: 1pt red on the failure banner, a 2pt accent ring on a recording
hotkey.

### Named Rules

**The Concentric Rule.** Inner radius = outer radius − inset. If a tile's corner
doesn't follow its parent's, change the inset or the radius until it does.

## Components

### Buttons

Tactile and confident: the one thing on screen that asks to be pressed.

- **Shape:** capsule, at least 46pt tall, with 22pt of horizontal and 12pt of
  vertical padding.
- **Primary (`StreamButtonStyle`):** the accent-surface gradient under Liquid
  Glass tinted with the accent at 0.25, a 0.5pt white rim fading from 10% to 2%
  top to bottom, the button lift shadow, and a title2 semibold label (17pt) in
  the primary label colour beside a 16pt play glyph. On the launcher it is up to
  380pt wide and answers Return; the menu bar panel's primary action is the same
  button.
- **Pressed:** scales to 0.985 over a 0.15s snappy spring; no colour change.
  Disabled drops to 55% opacity.
- **One button, changing verb:** the launcher's button reads Stream, Wake or
  Cancel as the state changes, and becomes the "Connecting to…" capsule during
  the handshake rather than adding a second surface. The play glyph bounces once
  when the stream goes live, unless Reduce Motion is on.
- **Secondary:** standard AppKit and SwiftUI buttons (bordered, borderless or
  plain) with no custom style. "Pair a PC…" in Settings is a standard button
  with a plus glyph.

### Chips

- **Readiness chip:** a glass capsule with 4 by 10pt of padding, a 7pt status
  dot, a caption-medium label and an optional 9pt route glyph (bolt for wired,
  Wi-Fi arcs for wireless). The dot pulses while your own stream is live, unless
  Reduce Motion is on.
- **Spec line:** not a chip. Resolution, refresh rate and codec are a single
  line of callout text in secondary colour, separated by middle dots, so nothing
  that is a fact looks pressable.

### Cards / Containers

- **Corner Style:** 26pt continuous for the launcher's PC card; 16pt for PC
  tiles in Settings; 12pt for inset panels.
- **Background:** the PC card is the accent-surface gradient at 55% opacity
  under Liquid Glass tinted 0.12. PC tiles and inset panels use plain glass or
  quaternary fill.
- **Shadow Strategy:** the card lift on the PC card only; tiles and panels rely
  on glass.
- **Border:** none.
- **Internal Padding:** 16pt.

### App Tiles

The launcher's signature row: shaped like the Home app's accessory tiles.

- **Layout:** a 15pt glyph in a 24pt frame, the app name in callout medium, a
  flexible gap, and a secondary play glyph trailing. At least 44pt tall with
  12pt of horizontal padding.
- **Surface:** interactive Liquid Glass with a 10pt radius, grouped in one glass
  container.
- **Behaviour:** one click streams that app. While a stream is running the grid
  dims to 45% and each tile is disabled, but the overflow menu stays open for
  browsing.

### Connect Banner

- Sits above the PC card only when a connection fails: the shared failure copy,
  a borderless dismiss button, 10 by 14pt of padding, glass tinted red at 0.12
  with a 1pt red stroke at 12pt radius. It slides in from the top and appears at
  once, never behind a delay.

### PC Tiles (Settings)

- The `display` glyph on a colour picked by hashing the PC's ID, the name in
  headline, the address in caption monospaced, and "Last played" in tertiary.
  The PC's apps appear as up to three plain secondary glyphs, not buttons. Plain
  glass at 16pt. The yellow star alone marks the default PC.

### Inputs / Fields

- **Style:** standard system text fields, pickers, toggles and steppers in a
  grouped Form. No custom field chrome.
- **Hotkey recorder:** an interactive glass capsule, at least 80 by 22pt,
  showing the chord in body medium monospaced text. While recording, the glass
  takes an accent tint (0.22), a 2pt accent ring and accent text; a rejected
  chord explains itself in a line underneath and recording stays open. A saved
  chord is announced to VoiceOver, and VoiceOver's own keys pass through.
- **Static key notation:** fixed chords appear as plain monospaced secondary
  text, not as badges, because they cannot be pressed.

### Navigation

- **Settings sidebar:** the standard source list, each row with an SF Symbol on
  a 6pt coloured glyph chip.
- **Stream menu:** in the main menu bar: Stream, Mini Player and Stop Streaming,
  then the PCs with a checkmark on the selected one and ⌘1 to ⌘9. The PCs lock
  while a stream is running.
- **Toolbar:** the gear alone when one PC or none is paired; with more, a PC
  menu joins it in one pill.
- **Menu bar panel:** 300pt wide, with cards on 12pt quaternary fill, each
  titled in headline with its value in secondary on the right, the way Tahoe's
  own panels are. The PC card has no title: the PC's name is the title. Big
  numbers are title semibold with monospaced digits; the chart draws bandwidth
  in the accent, latency in secondary and frames in green, with orange for a
  short second. The footer holds an "Open Glimmer" plain button, a glass gear
  for Settings and a "…" menu with "Check for Updates…" and "Quit Glimmer".

### Stream-Ended Toast

- A thin-material capsule with a 0.5pt hairline, "Stream ended" in callout
  medium and an optional receipt line in caption secondary. It slides down from
  the top edge (fades under Reduce Motion), stays 2 seconds (4 with a receipt)
  and is announced to VoiceOver.

## Do's and Don'ts

### Do:

- **Do** build every custom look as a style on a real control (a `ButtonStyle`
  on a `Button`, glass on a `Button`), keeping native focus, keyboard and
  VoiceOver behaviour.
- **Do** keep one primary capsule as the only full-strength Eclipse Violet on
  any screen, and the PC card at half strength.
- **Do** group glass siblings in one `GlassEffectContainer` with spacing equal
  to the layout gap (8pt).
- **Do** nest radii concentrically: 26pt card, 16pt inset, 10pt tiles.
- **Do** animate state with `.snappy` (0.3 to 0.35s, extra bounce 0.1). Under
  Reduce Motion the extra bounce is 0, slides become fades, and every pulse and
  bounce is off.
- **Do** use the `display` glyph for a PC, everywhere a PC is drawn.
- **Do** dim rather than hide the launcher's tiles while a stream is running
  (45% opacity).
- **Do** explain in footnote secondary text inside the control's label.

### Don't:

- **Don't** flatten the PC card to a neutral surface; a grey card reads as a
  blob. Keep the violet at half strength.
- **Don't** centre a narrow column in a wide card, or add a flexible frame to
  the launcher column; fill the width with structure or narrow the window.
- **Don't** redraw, recolour or reinterpret the app icon, and don't introduce a
  second brand hue.
- **Don't** style facts as controls: no chips, pills or glass behind the spec
  line, addresses or static key notation.
- **Don't** use coloured shadows, glows or upward light, and don't use colour
  fills for status.
- **Don't** draw a control from a shape with a tap gesture, or reach for web
  views or cross-platform UI.
- **Don't** use em dashes, emoji, exclamation marks, or "host" or "server" in
  anything a person reads.
