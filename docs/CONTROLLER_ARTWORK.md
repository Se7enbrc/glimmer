# Controller artwork

Edit the shared controller vectors in `Glimmer/ControllerLayouts` to keep Mac,
iPhone and iPad diagrams, control positions and hit regions together.

## Geometry and surfaces

`ControllerBodyShape` contains original Bézier silhouettes for DualSense,
DualShock 4, Xbox, Backbone One and generic MFi. DualSense Edge shares the
DualSense shell with its own function buttons and rear controls. Xbox Elite adds
its grip panels, round d-pad and exposed rear paddles. `ControllerSurfaceShape`
draws the trim, seams, light bars, speaker apertures and rear details. The style
follows technical line drawings: monochrome label and secondary-label strokes,
with a slightly heavier outer silhouette and lighter internal details. There are
no surface fills, gradients, shadows, textures or colored legends. The existing
selection feedback belongs to native controls. Shell lines are clipped behind
controls without adding opaque fills.

`ControllerShoulderGeometry` independently draws the five shoulder assemblies:
DualSense/Edge, DualShock 4, Xbox/Elite, Backbone and generic MFi. Bumpers
follow the top grip contours; front triggers sit behind both the bumper and
shell. Plain part lettering replaces boxed glyphs. Rear triggers retain their
exposed depth, with physical left/right mirrored. The approved body and face
controls keep their existing geometry and stroke weights.

On iOS, each close-set shoulder pair opens a native menu with separate bumper
and trigger choices. Its hit shape contains a 44 by 44 point core above the
other controls plus the visible parts. Mac selects each part directly. Selection
and pressed feedback color the actual part outline, never a detached chip.

`ControllerDiagramGeometry` places the controls in a 480 by 330 coordinate
space. The editor scales this space uniformly. Native buttons use
`ControllerButtonShape` for both their visible outline and full hit region;
stick and d-pad menus use the same centers and diameters as their artwork. Back
views mirror shoulder and trigger positions. The complete accessible list
remains available for small controls and replaces the diagram at accessibility
text sizes.

Interactive controls depend on reported capabilities. Decorative function tabs,
ports and trigger stops do not invent remappable inputs. The connection must
expose an input before Glimmer can assign it. Unknown extra-button positions
remain available in capture and the list.

## Reference provenance

Every curve is independently authored in Swift from observed construction and
relative proportions, checked against published overall dimensions. No image was
traced, sampled into a contour, copied, embedded or shipped. Manufacturer marks
come only from Apple's SF Symbols. Reference files stay outside the repository.
The Dimensions.com DualSense technical line drawing informs only the line-art
style, not its contours or vertices. All eight variants retain independently
authored geometry.

| Family                    | References consulted                                                                                                                                                                                                                       | Independent drawing decisions                                                                                                                                                                                                        |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| DualSense                 | [Sony parts guide](https://controller.dl.playstation.net/controller/lang/gb/2100002.html), [numeric envelope](https://www.dimensions.com/element/playstation-5-dualsense-controller)                                                       | Original symmetric shell and trim curves, broad rounded grip ends, tapered touchpad, separated directional buttons, speaker holes and lower symmetric sticks. The 160 × 106 mm envelope informs proportion, not individual vertices. |
| DualSense Edge            | [Sony parts guide](https://controller.dl.playstation.net/controller/lang/gb/2100003.html), [Sony product photographs](https://www.playstation.com/en-us/accessories/dualsense-edge-wireless-controller/)                                   | Independently drawn touchpad, face controls and center panel; front function tabs; rear panel, trigger stops and two lever attachments.                                                                                              |
| DualShock 4               | [Sony product photographs](https://www.playstation.com/en-us/accessories/dualshock-4-wireless-controller/), [Sony dimensions](https://www.playstation.com/pt-pt/ps4/tech-specs/)                                                           | Independently drawn rounded shoulder lobes, fuller grips, circular control surrounds, inset sticks and shorter touchpad. The 161 × 100 mm envelope is a proportion check.                                                            |
| Xbox Series               | [Microsoft product photographs](https://www.xbox.com/en-US/accessories/controllers/xbox-wireless-controller)                                                                                                                               | Original broad shell, offset sticks, faceted hybrid d-pad, compact View/Menu/Share arrangement and shoulder shelves. No illustration or logo paths were extracted.                                                                   |
| Xbox Elite Series 2       | [Microsoft front and rear gallery](https://www.xbox.com/en-US/accessories/controllers/elite-wireless-controller-series-2)                                                                                                                  | Independently drawn rubber grip panels, round faceted dish, profile button and indicators, rear trigger stops, short upper paddles and hooked lower paddles. The rear is an integrated housing, not a removable battery door.        |
| Backbone One, standard    | [Backbone product page](https://backbone.com/products/backbone-one/), [second-generation announcement photographs](https://backbone.com/blogs/news/backbone-one-gen-2-expand-your-play)                                                    | Original split shell curves, rounded cross d-pad, offset sticks and inward capture/home buttons. A neutral landscape phone establishes the extended bridge scale.                                                                    |
| Backbone One, PlayStation | [Backbone product page](https://backbone.com/products/backbone-one-playstation/), [PlayStation announcement photograph](https://blog.playstation.com/2023/05/23/backbone-one-playstation-edition-launches-on-android-today/)               | Independently drawn version of the same split shell, with cross d-pad and PlayStation face legends supplied by SF Symbols. There is no PlayStation home logo on this hardware.                                                       |
| Generic MFi               | [SteelSeries control overview](https://downloads.steelseriescdn.com/guides/Nimbus%2B_PIG_15.pdf), [MFi profile description](https://support.steelseries.com/hc/en-us/articles/4417961195533-Do-I-need-an-app-to-use-the-Nimbus-controller) | Independently drawn neutral shell with symmetric sticks and a cross d-pad. This illustrates the extended-gamepad control arrangement; it is not a Nimbus likeness or a promise about an unknown controller's enclosure.              |

## Limits of the projection

These are recognizable front/rear illustrations, not manufacturing drawings.
Shoulder shelves expose the triggers in the front view for editing; rear views
show their larger underside and mirror physical left/right. The Edge uses lever
back buttons rather than the optional half-domes. Elite uses the round faceted
d-pad and standard stick caps; interchangeable parts and alternate colors are
not inferred from connection metadata. Surface textures are omitted to keep the
line drawing clear.

Backbone uses the standard/PlayStation name reported by the connection or saved
record. Ambiguous names retain the standard art; reported glyphs always take
precedence. The bridge width varies with the installed phone and is
illustrative. First/second-generation connector and adapter changes are not
separate variants. Generic MFi and unknown extra-button coordinates cannot be
model-accurate. Inputs without positions stay in the accessible list rather than
receiving invented physical locations.

## Verification

Run only the touched `ControllerDiagramTests` and `ControllerLayoutRenderTests`
suites for an artwork revision. The geometry tests check family resolution,
control containment, nonoverlapping button bounds, touchpad bounds, mirrored
rear targets, shell-line occlusion, shoulder overlap and 44 point target cores
that clear the other buttons. Part labels remain inside their visible paths.
Native renders cover all families and the two paddle backs in light and dark on
Mac, iPhone Simulator and iPad Simulator. Mac tests also inspect the native
accessibility tree for every visible control and each stick/d-pad menu.

Inspect the exported boards at native and compact size before accepting changes.
Screenshots establish rendered appearance, not physical-controller or VoiceOver
interaction coverage. No artwork runs on the streaming input path, and there is
no timer or repeating animation.

Continue with the [controller guide](guides/CONTROLLERS.md) for the
player-facing layout and capture flow.

## Controller shortcuts

Record Stop streaming and Stats in Glimmer controls inside the existing layout
editor. New shortcuts require at least three simultaneous buttons held for 400
ms, then released. The diagram highlights the physical buttons while recording;
the review names them using the controller's labels. Cancel leaves the saved
shortcut untouched. Shortcuts apply to every game, independently of the PC
button layout.

Stop defaults to L1 + R1 + Create/Select + Options/Start. Stats defaults to L1 + R1 + L3 + R3.
Reject a shortcut that contains the other shortcut or fits inside it. Warn about
the commonly used L3 + R3, L1 + R1 and Start + Select pairs. Also warn when a
shortcut needs multiple buttons from one thumb: left stick, d-pad and Select on
the left; right stick, face buttons and Start on the right. Shoulders and
triggers use fingers. Saved Stats choices, including Select + L3 + R3, stay
intact until explicitly reset. Missing Stats choices use the current default. An
older saved Stop choice stays intact; if it overlaps the new Stats default,
Stats remains inactive until a nonconflicting shortcut is recorded.

Input is forwarded immediately, including the start of a shortcut. After the
hold, Glimmer releases its buttons to the PC and suppresses them until every
shortcut button is up, then performs the action. Games can briefly see those
buttons; no ordinary game press is reserved or delayed. Keyboard Stop (Control-Q
by default), the touch stream menu and General's Reset to defaults provide
recovery.
