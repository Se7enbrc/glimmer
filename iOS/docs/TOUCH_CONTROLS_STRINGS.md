# Touch control string inventory

All user-facing strings introduced or used in a new touch-control context are
listed below. Existing stream copy is retained. Test-only fixture labels are
listed separately.

| Context                             | Strings                                                                                                                                                              |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Element names                       | Left stick; Right stick; Directional pad; A; B; X; Y; Left shoulder; Right shoulder; Left trigger; Right trigger; Left stick click; Right stick click; Options; Menu |
| Compact glyphs                      | L1; R1; L2; R2; L3; R3                                                                                                                                               |
| Stream/editor commands              | Edit controls…; Show controls; Edit controls; Cancel; Done; Size; Opacity; Hide; Add control…; Reset layout…; Reset layout; OK                                       |
| Editor confirmation                 | Reset this app's layout?                                                                                                                                             |
| Editor collision explanation        | Move a control to make room.                                                                                                                                         |
| Insufficient space                  | Make this window larger to use touch controls.                                                                                                                       |
| Trigger hint                        | Press fully, then drag inward to reduce the trigger.                                                                                                                 |
| VoiceOver button actions and values | Hold; Release; Held; Released                                                                                                                                        |
| VoiceOver stick actions and values  | Up; Down; Left; Right; Center; Centered; “{horizontal percentage}, {vertical percentage}”                                                                            |
| VoiceOver trigger value             | “{integer percentage}%”                                                                                                                                              |
| Editor movement actions             | Move left; Move right; Move up; Move down                                                                                                                            |
| Mouse mode labels                   | Pointer; Scroll; Click; Right; Primary click; Secondary click                                                                                                        |

A/B/X/Y, controller element names, Show controls, Cancel, Done, Pointer, Scroll
and other standard words may already occur elsewhere in Glimmer. They are
included here because the new controls expose them. “Right” on the active
shoulder denotes a secondary click; the saved mouse-stick choice selects the
trigger and shoulder, exactly as in the existing engine mapping.

Test-only art says “ALPINE RUN” and “Illustrative sample frame”. Test
assertions, CSV headings, test names, storage keys, SF Symbol identifiers and
the named SwiftUI coordinate space are developer evidence, not product copy.

The per-session stream menu adds “Show touch controls” and “Hide touch
controls”. The item appears only during streaming with a physical controller
connected. The choice resets when the stream ends and has no Settings
counterpart.

Next:
[review implementation evidence and remaining acceptance gaps](TOUCH_CONTROLS_VALIDATION.md).

## Original opacity follow-up

The only new user-facing string is “Opacity”, used for the visible editor label
and the native slider's VoiceOver label. Its visible and accessible value uses
locale-formatted percentages (10% through 60%, default 20%). No new hint, alert,
menu item or Settings string is introduced.

## Overlay-wide opacity follow-up

New strings: “All controls” (the global section heading) and “Select a control
to move or resize it.” (the empty-selection instruction). “Size” is now a
visible row label under the selected control; its string is reused. “Opacity”,
its percentage value, “Hide”, and the menu button's “Show controls” label are
unchanged. All controls and the selected control's name are accessibility
headings.
