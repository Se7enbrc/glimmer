# Controller artwork

Edit the shared controller vectors in `Glimmer/ControllerLayouts` to keep Mac,
iPhone and iPad diagrams, control positions and hit regions together.

## Geometry and surfaces

`ControllerBodyShape` contains original Bézier silhouettes for DualSense,
DualShock 4, Xbox, Backbone One and generic MFi. DualSense Edge shares the
DualSense shell with its own dark touchpad and function buttons. Xbox Elite adds
its exposed rear paddles. `ControllerSurfaceShape` draws the trim, seams, light
bars, speaker apertures and rear details. `ControllerArtwork` shades those
surfaces with system material, neutral gradients and static highlights.

`ControllerDiagramGeometry` places the controls in a 480 by 330 coordinate
space. The editor scales this space uniformly. Native buttons use
`ControllerButtonShape` for both their visible surface and hit region; stick and
d-pad menus use the same centers and diameters as their artwork. Back views
mirror shoulder and trigger positions. The complete accessible list remains
available for small controls and replaces the diagram at accessibility text
sizes.

Interactive controls depend on reported capabilities. Decorative function tabs,
ports and trigger stops do not invent remappable inputs. The connection must
expose an input before Glimmer can assign it. Unknown extra-button positions
remain available in capture and the list.

## Measurements and original artwork

The paths were authored directly in Swift. No reference image, stock artwork,
drawing, logo outline or extracted vector was copied, traced or embedded. The
only manufacturer marks displayed are Apple's SF Symbols supplied through the
controller glyph path. Published dimensions inform the envelope; internal curves
and control positions are original illustrative geometry, not manufacturing CAD.

- DualSense: approximately 160 by 106 mm in front projection, with 66 mm depth.
  [Sony's PS5 FAQ](https://blog.playstation.com/2020/11/09/ps5-the-ultimate-faq/)
  and the numeric measurements on the
  [requested dimensions page](https://www.dimensions.com/element/playstation-5-dualsense-controller).
- DualSense Edge: approximately 160 by 106 by 66 mm in the
  [Sony product sheet](https://boulanger.scene7.com/is/content/Boulanger/0711719593072_f_0).
- DualShock 4: approximately 161 by 100 mm in front projection, with 57 mm
  depth.
  [Sony's technical specifications](https://www.playstation.com/pt-pt/ps4/tech-specs/).
- Xbox: Microsoft's published controller envelope is approximately 153 by 102 by
  61 mm. This older measurement is a family proportion reference, not a claim of
  a newly measured Series or Elite enclosure.
  [Microsoft specification sheet](https://download.microsoft.com/download/7/C/A/7CA6D7FD-9758-4DA8-BD27-4FDAB0C18E1F/TDS_XboxOneControllerPlusCableforWindows.pdf).
- Backbone One: the second generation extends from 176.3 to 265 mm wide. Its
  bridge is drawn extended around a landscape phone, rather than at the folded
  width.
  [Backbone dimensions](https://help.backbone.com/hc/es-419/articles/4405915657239--Qu%C3%A9-dimensiones-tiene-el-controlador-Backbone-One).

Generic MFi has no single hardware envelope. It deliberately uses an original
neutral controller silhouette. Alternate colors, replaceable caps, optional
half-dome Edge back buttons and third-party housings are not separate artwork
variants. The Edge rear illustration uses the lever attachment.

## Verification

Run only the touched `ControllerDiagramTests` and `ControllerLayoutRenderTests`
suites for an artwork revision. The geometry tests check family resolution,
control containment, nonoverlapping button bounds, touchpad bounds and mirrored
rear targets. Native renders cover all families and the two paddle backs in
light and dark on Mac, iPhone Simulator and iPad Simulator.

Inspect the exported boards at native and compact size before accepting changes.
Screenshots establish rendered appearance, not physical-controller or VoiceOver
interaction coverage. No artwork runs on the streaming input path, and there is
no timer or repeating animation.

Continue with the [controller guide](guides/CONTROLLERS.md) for the
player-facing layout and capture flow.
