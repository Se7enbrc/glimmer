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
  pc-name:
    fontFamily: "SF Pro Display, -apple-system, system-ui, sans-serif"
    fontSize: "22px"
    fontWeight: 600
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
  button:
    fontFamily: "SF Pro Text, -apple-system, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 700
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
  app-button: "14px"
  pc-tile: "16px"
  capsule: "9999px"
spacing:
  hairline: "2px"
  xs: "4px"
  sm: "8px"
  gutter: "10px"
  md: "12px"
  lg: "16px"
  margin: "24px"
components:
  app-button:
    backgroundColor: "{colors.eclipse-violet}"
    textColor: "#FFFFFF"
    typography: "{typography.button}"
    rounded: "{rounded.app-button}"
    padding: "0 16px"
    height: "60px"
  stream-button:
    backgroundColor: "{colors.eclipse-violet}"
    textColor: "#FFFFFF"
    typography: "{typography.headline}"
    rounded: "{rounded.capsule}"
    padding: "12px 22px"
    height: "46px"
  pc-header:
    textColor: "{colors.label}"
    typography: "{typography.pc-name}"
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
ready, and here are its apps, one click from playing. Everything that isn't that
sentence belongs to macOS: its materials, its type, its controls, its menus. The
only thing Glimmer brings of its own is Eclipse Violet, and it appears only
where you act.

Surfaces are tactile, but taste comes first. The things you can press feel like
objects: Liquid Glass that refracts what sits behind the window, a soft downward
shadow, a slight give when pressed (scale 0.985). Everything else stays flat:
facts, labels, explanations and status sit as plain text on the glass, with no
chrome. Depth marks what can be pressed or what floats above the window, never
decoration.

The launcher is one sheet of frosted glass, sized to its content. The PC's name
is its title and its switcher, the specs sit under the name, and each app is a
violet button that streams it. There is no card inside the window: the window is
the surface. Four looks have been tried and rejected: a neutral grey card (the
"grey blob"), a narrow centred column in a wide card, a washed-out mauve card
(the accent at low opacity over grey reads dusty), and a dark violet card lit
from below, which read as flashy. The app icon is final and is not redrawn,
recoloured or reinterpreted.

**Key Characteristics:**

- One brand hue, Eclipse Violet, used only where you act: the app buttons, the
  state button and a primary capsule.
- The launcher is one sheet of frosted Liquid Glass with no card inside it.
- Liquid Glass and soft black shadows only on things you can press or that
  float.
- SF system text styles throughout; footnote-size secondary text does the
  explaining.
- Continuous (squircle) corners, concentric where one shape sits in another.
- Windows sized to their content; no empty space, no stretched columns.
- Motion is snappy and short, and every pulse or bounce respects Reduce Motion.

## Colors

One saturated violet on frosted glass, with the status colours that macOS
already uses.

### Primary

- **Eclipse Violet** (#6B0F9E light, oklch(41.7% 0.203 308)): the accent colour
  of the app (`AccentColor`). The surface of the launcher's app buttons and its
  state button, the menu bar panel's primary button, "Pair a PC…" in the empty
  state and the pair sheet's main action. As a tint: the PC glyph in the
  launcher's header, switches, focus rings and the pairing glyph.
- **Eclipse Violet, night** (#A847E0 dark, oklch(59.5% 0.227 310)): the same
  accent in dark appearance, lifted so it reads against dark glass without
  glowing.

The primary surface is the accent itself, opaque: lightened with 10% white at
the top left and deepened with 18% black at the bottom right, under Liquid Glass
tinted with the accent at 0.15, with a 1pt white rim fading from 30% to 2% top
to bottom.

### Neutral

- **Label** (#000000D9, white at 85% in dark): primary text: PC names, app
  names, button labels.
- **Secondary Label** (#00000080, white at 55% in dark): explanations, the spec
  line, trailing play glyphs, addresses.
- **Tertiary Label** (#0000003F, white at 25% in dark): the quietest facts, such
  as "Last played".
- Backgrounds are glass and system materials rather than colours: frosted Liquid
  Glass for the launcher window, thin material on Settings, sheets and the
  toast, quaternary fills for inset panels.

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

**The Violet Acts Rule.** Violet fills only what acts: the app buttons, the
state button and a primary capsule; elsewhere it is a tint on a glyph. Never put
a violet or grey slab behind content; the glass is the surface.

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
- **PC name** (semibold 600, 22pt, the title style): the launcher's title.
- **Headline** (semibold 600, 17pt, the title2 style): the state button's label.
- **Title** (regular 400, 15pt, the title3 style): the empty state's supporting
  line and the few section titles outside a Form.
- **Body** (regular 400, 13pt): the spec line under the PC name, Settings rows,
  menu items and form labels.
- **Button** (bold 700, 13pt, the headline style): the app buttons' names.
- **Label** (medium 500, 12pt, the callout style): the toast's title.
- **Caption** (regular 400, 10pt, the footnote and caption styles): the
  explanatory line under a toggle, the readiness chip (in medium weight), and
  the "Last played" line.

### Named Rules

**The System Voice Rule.** Use text styles, not point sizes. Fixed sizes are
allowed only for SF Symbol glyph sizing and the empty state's display line.

**The Footnote Explains Rule.** An explanation sits in footnote-size secondary
text inside the control's own label, directly under its title, never as a loose
paragraph elsewhere in the pane.

## Layout

The launcher is a content-sized window of frosted Liquid Glass: its column ends
in `.fixedSize(horizontal: false, vertical: true)`, and the window is 580pt
wide, 532pt of content in 24pt side margins. The title bar holds the traffic
lights on the leading edge and the Settings gear on the trailing edge. Under it,
16pt apart: a failure banner when there is one; the header (the PC glyph, the
PC's name with the spec line under it, a flexible gap and the readiness chip); a
two-column grid of app buttons with 10pt gutters; the state button, only when
the PC needs something other than a stream; and the "Last played" footer. The
grid shows at most four cells; beyond four apps, the fourth is a menu of the
rest.

Settings is a standard split view (sidebar plus a grouped Form) in its own
window, with a minimum size of 680 by 540pt. The menu bar panel is 300pt wide.

The spacing rhythm is 8pt: 8 and 10 are the everyday gaps, 16 and 24 separate
groups and frame the window, and 2, 4 and 6 are fine steps inside a control.

### Named Rules

**The Sized-to-Content Rule.** Windows are exactly as big as their contents. No
`minHeight` floor, no `maxWidth: .infinity` and no trailing `Spacer` on the
launcher column; prove a geometry change with the osascript window check in
CONTRIBUTING.

**The No Empty Aisles Rule.** A narrow column centred in a wide container reads
as wasted space. Fill the width with structure (a header row, a grid) or narrow
the container.

## Elevation & Depth

Glimmer is tactile but restrained, with depth reserved for surfaces that respond
to touch or float over the window. Liquid Glass (`.glassEffect`) is the primary
depth cue. The launcher window itself is frosted Liquid Glass, see-through
enough to show colour behind it and blurred enough that text behind turns to
colour. On it: the app buttons and the state button on the primary surface,
plain glass on the readiness chip, the gear and the overflow menu, and plain
glass on the PC tiles in Settings. The refraction and colour behind the glass
come from the desktop showing through, not from a gradient to remove. Shadows
are black, soft and always cast downward.

### Shadow Vocabulary

- **Button lift** (black 18%, radius 12, y 4): the app buttons, the state button
  and every primary capsule.
- **Icon lift** (black 20%, radius 10, y 4): the app icon on the About pane.
- **Toast float** (black 12%, radius 8, y 4): the "Stream ended" toast.

### Named Rules

**The Press, Not Pose Rule.** Depth (glass, shadow or scale) marks something you
can press or something floating above the window. Facts and labels sit flat on
the glass.

**The One Light Rule.** Every shadow is black, at 12 to 20% opacity, offset
downward. No coloured glows, no inner shadows, no upward light.

## Shapes

Every corner is continuous (a squircle), never circular. Radii nest where one
shape sits inside another (the menu bar panel's cards, the pair sheet's panels).
Capsules mark a single action or a single state (the state button, the readiness
chip, the toast, the gear). Rounded rectangles mark containers and the app
buttons: 6pt for glyph chips in the sidebar and menu bar, 8pt for small controls
and badges, 10pt for the pair sheet's rows, 12pt for inset panels, 14pt for the
launcher's app buttons and 16pt for PC tiles. Borders are hairline strokes at
0.5pt and low opacity, used only where material alone would disappear (the
toast, the empty state's medallion); the primary surface carries a 1pt lit rim.
Heavier strokes carry state: 1pt red on the failure banner, a 2pt accent ring on
a recording hotkey.

### Named Rules

**The Concentric Rule.** Inner radius = outer radius − inset. If a shape's
corner doesn't follow its parent's, change the inset or the radius until it
does.

## Components

### Buttons

Tactile and confident: the things on screen that ask to be pressed.

- **App buttons (`AppTileStyle`):** the launcher's main actions. 60pt tall with
  a 14pt radius, a 20pt glyph, the app name in bold headline, and a play glyph
  trailing at 75%, all white on the primary surface. One click streams that app,
  and Return streams the Start with app while the PC is ready. The app that is
  launching or streaming carries its own state, with the readiness chip as the
  status: during a slow connect or a reconnect its play glyph becomes a spinner
  and a click or Escape is the way out; while its stream window is hidden it
  stays violet, reads “Back to Stream” in place of its play glyph, and a click
  or Return goes back to the stream. The other app buttons dim while a stream
  exists.
- **State button (`StreamButtonStyle`):** a capsule at least 46pt tall, with
  22pt of horizontal and 12pt of vertical padding, white title2 semibold label.
  It appears under the app buttons only when the PC needs something other than a
  stream: Wake and Connect and Pair Again…, and Connecting… or Back to Stream
  for a stream with no app button of its own, from the overflow menu, the menu
  bar or Shortcuts. A fast connect shows nothing: both wait out a 400ms hold.
  The same style is the menu bar panel's primary button, "Pair a PC…" and the
  pair sheet's main action.
- **Pressed:** scales to 0.985 over a 0.15s snappy spring; no colour change.
  Disabled drops to 55% opacity.
- **Secondary:** standard AppKit and SwiftUI buttons (bordered, borderless or
  plain) with no custom style. "Pair a PC…" in Settings is a standard button
  with a plus glyph.

### Chips

- **Readiness chip:** a glass capsule with 4 by 10pt of padding, a 7pt status
  dot, a caption-medium label and an optional 9pt route glyph (a cable plug for
  wired, Wi-Fi arcs for wireless). The dot pulses while your own stream is live,
  unless Reduce Motion is on.
- **Spec line:** not a chip. Resolution, refresh rate and codec are a single
  line of body text in secondary colour under the PC's name, separated by middle
  dots, so nothing that is a fact looks pressable.

### PC Header

- The launcher's title: the `display` glyph at 30pt in the accent, the PC's name
  in title semibold with the spec line under it, and the readiness chip on the
  trailing edge. With more than one PC paired, the name is a menu with a chevron
  that lists the PCs with a checkmark on the selected one. Right-click opens the
  PC's own menu (rename, codec, Wake on LAN, unpair).

### Cards / Containers

- **Corner Style:** 16pt for PC tiles in Settings; 12pt for inset panels. The
  launcher has no card: the window is the surface.
- **Background:** plain glass or quaternary fill.
- **Border:** none.
- **Internal Padding:** 16pt.

### Connect Banner

- Sits at the top of the launcher only when a connection fails: the shared
  failure copy, a borderless dismiss button, 10 by 14pt of padding, glass tinted
  red at 0.12 with a 1pt red stroke at 12pt radius. It slides in from the top
  and appears at once, never behind a delay.

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
- **Toolbar:** only the Settings gear, on the trailing edge; the PC switcher is
  the header's name.
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
- **Do** keep violet to what acts: the app buttons, the state button, a primary
  capsule, and the PC glyph as a tint.
- **Do** group plain-glass siblings in one `GlassEffectContainer` with spacing
  equal to the layout gap, and never wrap filled controls in one: it composites
  the glass over their labels.
- **Do** nest radii concentrically wherever one shape sits inside another.
- **Do** animate state with `.snappy` (0.3 to 0.35s, extra bounce 0.1). Under
  Reduce Motion the extra bounce is 0, slides become fades, and every pulse and
  bounce is off.
- **Do** use the `display` glyph for a PC, everywhere a PC is drawn.
- **Do** disable (55% opacity) rather than hide the app buttons while a stream
  is running.
- **Do** explain in footnote secondary text inside the control's label.

### Don't:

- **Don't** put a slab behind the launcher's content: a grey card reads as a
  blob, a pale violet one as dust and a dark violet one as flashy. The window is
  the surface.
- **Don't** centre a narrow column in a wide container, or add a flexible frame
  to the launcher column; fill the width with structure or narrow the window.
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
