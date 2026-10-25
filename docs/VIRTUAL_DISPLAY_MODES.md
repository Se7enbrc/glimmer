# Virtual display mode reference

Use this reference to maintain the [virtual display samples](vdd/) against the
client code and Apple's display specifications. For installation, follow the
[PC setup guide](HOST_SETUP.md).

## What Glimmer sends

The following rules describe this checkout, checked on 2026-10-24. Panel tables
below use landscape stream requests and hardware maximum refresh rates. Both
clients round each requested dimension down to an even number of pixels. Runtime
display reports remain authoritative.

| Choice                 | Request rule                                                                                                                                                      | Source                                                                                                            |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Mac Sharpest           | Panel-native pixels from Core Graphics; both dimensions rounded down to even. FPS is `NSScreen.maximumFramesPerSecond`, or 60 if unavailable.                     | [QualityCalculator.swift](../Glimmer/QualityCalculator.swift), `mainDisplayMode`, `effectiveValuesForPreset`      |
| Mac Balanced           | Integer half dimensions when both are at least 1280 × 720; otherwise native. Round the result down to even. Same FPS as Sharpest.                                 | [StreamQuality.swift](../GlimmerEngine/Session/StreamQuality.swift), `hidpiSize`, `encodableSize`                 |
| Mac Custom             | Width 640–7680, height 480–4320, integer FPS 30–240. Round dimensions down to even. Full screen preserves FPS; windowed caps to the display, with a 30 fps floor. | [bounds](../GlimmerEngine/Models/StreamSizeBounds.swift), [window cap](../Glimmer/Models/StreamDisplayMode.swift) |
| Mac common-size menu   | 1280 × 720, 1920 × 1080, 2560 × 1440, 3840 × 2160. These change Custom's size, not its FPS.                                                                       | [CommonResolution](../Glimmer/SettingsGeneralStreamingPanes.swift)                                                |
| iPhone and iPad Native | Target the window's physical pixels, preserving orientation and rounding down to even; choose the closest listed mobile mode under the display/120 fps cap.       | [StreamProfile.swift](../iOS/Glimmer/StreamProfile.swift), [catalog](../iOS/Glimmer/StreamDisplayModes.swift)     |
| iPhone and iPad 1080p  | 1920 × 1080 at the highest listed rate up to 60 or 120 fps and the display maximum.                                                                               | [StreamProfile.swift](../iOS/Glimmer/StreamProfile.swift)                                                         |

Both mobile devices bundle [iphone-ipad.xml](vdd/iphone-ipad.xml) and request
only its listed combinations. Native minimizes the worst proportional
width/height error, then aspect-fill cropping, then chooses the highest eligible
refresh. The [window contract](IPAD_WINDOW_STREAMING.md) defines the ranking and
fixed-format resize behavior. iPhone locks streams to landscape; iPad keeps the
window's orientation. 1080p remains 16:9 on both, with cropping to fill.

Both clients use
[StreamQuality.encodableSize](../GlimmerEngine/Session/StreamQuality.swift)
before creating the stream configuration. The shared
[launch query](../GlimmerEngine/Network/NetworkClient+Endpoints.swift) sends
these dimensions and FPS in `mode` and sets `sops=1`, which enables Sunshine's
automatic resolution selection. Mobile mode selection happens before this query;
the query does not change it. macOS display probing can fall back to a Retina
mode or framebuffer size when the panel-native flag is unavailable.

A 2436 × 1125 iPhone panel requests **2436 × 1124**. A 2556 × 1179 panel
requests **2556 × 1178**. The table and XML use these even requests, while the
linked Apple specifications give the physical panel sizes.

## Mac displays

Each row gives Sharpest and the actual Balanced request. FPS normally equals the
maximum shown. The matching samples also include 48, 50 and 60 for MacBook Pro
and Pro Display XDR fixed-refresh use, and common lower integer rates for
Custom. Fractional rates such as 59.94 are not selectable as Glimmer FPS.

| Models and Apple specifications                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Sharpest    | Balanced    | Maximum Hz |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------- | ---------- |
| [MacBook Air (15-inch, M5)](https://support.apple.com/en-us/126321), [MacBook Air (15-inch, M4, 2025)](https://support.apple.com/en-us/122210), [MacBook Air (15-inch, M3, 2024)](https://support.apple.com/en-us/118552), [MacBook Air (15-inch, M2, 2023)](https://support.apple.com/en-us/111346)                                                                                                                                                                                                                                                                                                     | 2880 × 1864 | 1440 × 932  | 60         |
| [MacBook Air (13-inch, M5)](https://support.apple.com/en-us/126320), [MacBook Air (13-inch, M4, 2025)](https://support.apple.com/en-us/122209), [MacBook Air (13-inch, M3, 2024)](https://support.apple.com/en-us/118551), [MacBook Air (M2, 2022)](https://support.apple.com/en-us/111867)                                                                                                                                                                                                                                                                                                              | 2560 × 1664 | 1280 × 832  | 60         |
| [MacBook Air (M1, 2020)](https://support.apple.com/en-us/111883), [MacBook Pro (13-inch, M2, 2022)](https://support.apple.com/en-us/111869), [MacBook Pro (13-inch, M1, 2020)](https://support.apple.com/en-us/111893)                                                                                                                                                                                                                                                                                                                                                                                   | 2560 × 1600 | 1280 × 800  | 60         |
| [MacBook Pro (14-inch, M5 Pro or M5 Max)](https://support.apple.com/en-us/126318), [MacBook Pro (14-inch, M5)](https://support.apple.com/en-us/125405), [MacBook Pro (14-inch, 2024)](https://support.apple.com/en-us/121552), [MacBook Pro (14-inch, 2024)](https://support.apple.com/en-us/121553), [MacBook Pro (14-inch, Nov 2023)](https://support.apple.com/en-us/117735), [MacBook Pro (14-inch, Nov 2023)](https://support.apple.com/en-us/117736), [MacBook Pro (14-inch, 2023)](https://support.apple.com/en-us/111340), [MacBook Pro (14-inch, 2021)](https://support.apple.com/en-us/111902) | 3024 × 1964 | 1512 × 982  | 120        |
| [MacBook Pro (16-inch, M5 Pro or M5 Max)](https://support.apple.com/en-us/126319), [MacBook Pro (16-inch, 2024)](https://support.apple.com/en-us/121554), [MacBook Pro (16-inch, Nov 2023)](https://support.apple.com/en-us/117737), [MacBook Pro (16-inch, 2023)](https://support.apple.com/en-us/111838), [MacBook Pro (16-inch, 2021)](https://support.apple.com/en-us/111901)                                                                                                                                                                                                                        | 3456 × 2234 | 1728 × 1116 | 120        |
| [iMac (24-inch, 2024, Four ports)](https://support.apple.com/en-us/121557), [iMac (24-inch, 2024, Two ports)](https://support.apple.com/en-us/121556), [iMac (24-inch, 2023, Four ports)](https://support.apple.com/en-us/117734), [iMac (24-inch, 2023, Two ports)](https://support.apple.com/en-us/117733), [iMac (24-inch, M1, 2021)](https://support.apple.com/en-us/111895)                                                                                                                                                                                                                         | 4480 × 2520 | 2240 × 1260 | 60         |
| [MacBook Neo](https://support.apple.com/en-us/126322)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | 2408 × 1506 | 2408 × 1506 | 60         |

### Apple external displays

| Display and Apple specifications                                                                                                      | Sharpest    | Balanced    | Maximum Hz |
| ------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------- | ---------- |
| [Studio Display (2022)](https://support.apple.com/en-us/111890), [Studio Display (2026)](https://www.apple.com/studio-display/specs/) | 5120 × 2880 | 2560 × 1440 | 60         |
| [Studio Display XDR](https://www.apple.com/studio-display-xdr/specs/)                                                                 | 5120 × 2880 | 2560 × 1440 | 120        |
| [Pro Display XDR](https://support.apple.com/en-us/111892)                                                                             | 6016 × 3384 | 3008 × 1692 | 60         |

Studio Display XDR is capped at 60 Hz on M1, M1 Pro, M1 Max, M1 Ultra, M2 and M3
Macs. Its Apple specification lists the compatible Mac and iPad models. The
Apple-display sample includes both 60 and 120 Hz for Studio Display XDR, and
48/50/60 for Pro Display XDR. MacBook Neo's integer half size is 1204 × 753, so
Balanced retains 2408 × 1506. The built-in sample also includes the optional
half size **1204 × 752**, rounded down to even, for Mac Custom.

### Macs with separate displays

These Apple Silicon Macs have no built-in panel. Sharpest, Balanced and the FPS
come from the attached display, not the chip's maximum video-output capability.
The sample includes Apple displays and common external sizes, but cannot cover
every third-party display or a portrait Mac display automatically.

- [Mac mini (M6)](https://support.apple.com/en-us/128108),
  [Mac mini (M5 Pro)](https://support.apple.com/en-us/128108),
  [Mac mini (2024)](https://support.apple.com/en-us/121555),
  [Mac mini (2023)](https://support.apple.com/en-us/111837),
  [Mac mini (M1, 2020)](https://support.apple.com/en-us/111894).
- [Mac Studio (M5 Max)](https://support.apple.com/en-us/128107),
  [Mac Studio (M5 Ultra)](https://support.apple.com/en-us/128107),
  [Mac Studio (2025)](https://support.apple.com/en-us/122211),
  [Mac Studio (2023)](https://support.apple.com/en-us/111835),
  [Mac Studio (2022)](https://support.apple.com/en-us/111900).
- [Mac Pro (2023)](https://support.apple.com/en-us/111343),
  [Mac Pro (Rack, 2023)](https://support.apple.com/en-us/111343).

The model inventories are Apple's
[MacBook Air](https://support.apple.com/en-us/102869),
[MacBook Pro](https://support.apple.com/en-us/108052),
[iMac](https://support.apple.com/en-us/108054),
[Mac mini](https://support.apple.com/en-us/102852),
[Mac Studio](https://support.apple.com/en-us/102231) and
[Mac Pro](https://support.apple.com/en-us/102887) lists. All Apple Silicon
variants in these families are covered by the panel rules above, including Mac
mini M1, M2/M2 Pro, M4/M4 Pro and M6/M5 Pro; Mac Studio M1 Max/Ultra, M2
Max/Ultra, M4 Max/M3 Ultra and M5 Max/Ultra; and M2 Ultra Mac Pro tower/rack.
They require macOS 15.7 or later; newer models require their supplied OS or
later.

## iPhone

Every model on Apple's
[iOS 26 compatibility list](https://support.apple.com/guide/iphone/iphone-models-compatible-with-ios-26-iphe3fa5df43/26/ios/26)
is listed below. The native FPS is the maximum shown, capped by the runtime
screen report. The sample includes 60 and 120 for each ProMotion size, and 60
for the others. Both 1080p profiles are available on every model, with the same
screen cap. Standard displays are 60 Hz; ProMotion supports up to 120 Hz through
[`UIScreen.maximumFramesPerSecond`](https://developer.apple.com/documentation/uikit/uiscreen/maximumframespersecond).

| Models and Apple specifications                                                                                                                                                                                                                                                                                                    | Native landscape request | Maximum Hz |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ | ---------- |
| [iPhone SE (3rd generation)](https://support.apple.com/en-us/111866), [iPhone SE (2nd generation)](https://support.apple.com/en-us/111882)                                                                                                                                                                                         | 1334 × 750               | 60         |
| [iPhone 11](https://support.apple.com/en-us/111865)                                                                                                                                                                                                                                                                                | 1792 × 828               | 60         |
| [iPhone 13 mini](https://support.apple.com/en-us/111873), [iPhone 12 mini](https://support.apple.com/en-us/111877)                                                                                                                                                                                                                 | 2340 × 1080              | 60         |
| [iPhone 11 Pro](https://support.apple.com/en-us/111879)                                                                                                                                                                                                                                                                            | 2436 × 1124              | 60         |
| [iPhone 17e](https://support.apple.com/en-us/126470), [iPhone 16e](https://support.apple.com/en-us/122208), [iPhone 14](https://support.apple.com/en-us/111850), [iPhone 13](https://support.apple.com/en-us/111872), [iPhone 12 Pro](https://support.apple.com/en-us/111875), [iPhone 12](https://support.apple.com/en-us/111876) | 2532 × 1170              | 60         |
| [iPhone 13 Pro](https://support.apple.com/en-us/111871)                                                                                                                                                                                                                                                                            | 2532 × 1170              | 120        |
| [iPhone 16](https://support.apple.com/en-us/121029), [iPhone 15](https://support.apple.com/en-us/111831)                                                                                                                                                                                                                           | 2556 × 1178              | 60         |
| [iPhone 15 Pro](https://support.apple.com/en-us/111829), [iPhone 14 Pro](https://support.apple.com/en-us/111849)                                                                                                                                                                                                                   | 2556 × 1178              | 120        |
| [iPhone 17 Pro](https://support.apple.com/en-us/125090), [iPhone 17](https://support.apple.com/en-us/125089), [iPhone 16 Pro](https://support.apple.com/en-us/121031)                                                                                                                                                              | 2622 × 1206              | 120        |
| [iPhone 11 Pro Max](https://support.apple.com/en-us/111878)                                                                                                                                                                                                                                                                        | 2688 × 1242              | 60         |
| [iPhone Air](https://support.apple.com/en-us/125092)                                                                                                                                                                                                                                                                               | 2736 × 1260              | 120        |
| [iPhone 14 Plus](https://support.apple.com/en-us/111854), [iPhone 12 Pro Max](https://support.apple.com/en-us/111874)                                                                                                                                                                                                              | 2778 × 1284              | 60         |
| [iPhone 13 Pro Max](https://support.apple.com/en-us/111870)                                                                                                                                                                                                                                                                        | 2778 × 1284              | 120        |
| [iPhone 16 Plus](https://support.apple.com/en-us/121030), [iPhone 15 Plus](https://support.apple.com/en-us/111830)                                                                                                                                                                                                                 | 2796 × 1290              | 60         |
| [iPhone 15 Pro Max](https://support.apple.com/en-us/111828), [iPhone 14 Pro Max](https://support.apple.com/en-us/111846)                                                                                                                                                                                                           | 2796 × 1290              | 120        |
| [iPhone 17 Pro Max](https://support.apple.com/en-us/125091), [iPhone 16 Pro Max](https://support.apple.com/en-us/121032)                                                                                                                                                                                                           | 2868 × 1320              | 120        |

### Additional iOS 27 models

Apple's [current iPhone inventory](https://support.apple.com/en-us/108044) also
lists these newer models. Their modes are included in addition to the iOS 26
set. The two Duo sizes describe the screens independently; this is not a claim
that changing screens during a stream has been verified.

| Model and Apple specifications                                      | Native landscape request  | Maximum Hz |
| ------------------------------------------------------------------- | ------------------------- | ---------- |
| [iPhone 18 Pro](https://support.apple.com/en-us/148590)             | 2622 × 1206               | 120        |
| [iPhone 18 Pro Max](https://support.apple.com/en-us/148591)         | 2868 × 1320               | 120        |
| [iPhone Duo](https://www.apple.com/iphone-duo/specs/), open / cover | 2670 × 1878 / 2034 × 1398 | 120        |

### Duo Simulator measurement

On Xcode 27.1 with iOS 27.1 (24A94232), the active Duo inner screen reports
`nativeBounds` of 2007 × 2853 pixels and `maximumFramesPerSecond` of 60. Glimmer
requests the closest listed mode rather than this exact size. Both samples are
at their 90-mode budget and omit this Simulator-only inner mode; the published
2670 × 1878 hardware size above remains in both. Add it by replacing an unused
mode using the [combining instructions](HOST_SETUP.md#combine-two-files).

## iPad

Every model on Apple's
[iPadOS 26 compatibility list](https://support.apple.com/guide/ipad/ipad-models-compatible-with-ipados-26-ipad213a25b2/26/ipados/26)
is listed below. Native uses the maximum shown, subject to the screen report.
The 1080p choices are the same as iPhone. All listed iPad Pro models have
ProMotion; Air, mini and standard iPad models use 60 Hz.

| Models and Apple specifications                                                                                                                                                                                                                                                                                                                                                                                                                                     | Native landscape request | Maximum Hz |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ | ---------- |
| [iPad mini (5th generation)](https://support.apple.com/en-us/111904)                                                                                                                                                                                                                                                                                                                                                                                                | 2048 × 1536              | 60         |
| [iPad (9th generation)](https://support.apple.com/en-us/111898), [iPad (8th generation)](https://support.apple.com/en-us/118451)                                                                                                                                                                                                                                                                                                                                    | 2160 × 1620              | 60         |
| [iPad Air (3rd generation)](https://support.apple.com/en-us/111939)                                                                                                                                                                                                                                                                                                                                                                                                 | 2224 × 1668              | 60         |
| [iPad mini (A17 Pro)](https://support.apple.com/en-us/121456), [iPad mini (6th generation)](https://support.apple.com/en-us/111886)                                                                                                                                                                                                                                                                                                                                 | 2266 × 1488              | 60         |
| [iPad Air 11-inch (M4)](https://support.apple.com/en-us/126471), [iPad Air 11-inch (M3)](https://support.apple.com/en-us/122241), [iPad Air 11-inch (M2)](https://support.apple.com/en-us/119894), [iPad Air (5th generation)](https://support.apple.com/en-us/111887), [iPad Air (4th generation)](https://support.apple.com/en-us/111905), [iPad (A16)](https://support.apple.com/en-us/122240), [iPad (10th generation)](https://support.apple.com/en-us/111840) | 2360 × 1640              | 60         |
| [iPad Pro 11-inch (4th generation)](https://support.apple.com/en-us/111842), [iPad Pro 11-inch (3rd generation)](https://support.apple.com/en-us/111897), [iPad Pro 11-inch (2nd generation)](https://support.apple.com/en-us/118452), [iPad Pro 11-inch](https://support.apple.com/en-us/111974)                                                                                                                                                                   | 2388 × 1668              | 120        |
| [iPad Pro 11-inch (M5)](https://support.apple.com/en-us/125406), [iPad Pro 11-inch (M4)](https://support.apple.com/en-us/119892)                                                                                                                                                                                                                                                                                                                                    | 2420 × 1668              | 120        |
| [iPad Air 13-inch (M4)](https://support.apple.com/en-us/126472), [iPad Air 13-inch (M3)](https://support.apple.com/en-us/122242), [iPad Air 13-inch (M2)](https://support.apple.com/en-us/119893)                                                                                                                                                                                                                                                                   | 2732 × 2048              | 60         |
| [iPad Pro 12.9-inch (6th generation)](https://support.apple.com/en-us/111841), [iPad Pro 12.9-inch (5th generation)](https://support.apple.com/en-us/111896), [iPad Pro 12.9-inch (4th generation)](https://support.apple.com/en-us/111977), [iPad Pro 12.9-inch (3rd generation)](https://support.apple.com/en-us/111979)                                                                                                                                          | 2732 × 2048              | 120        |
| [iPad Pro 13-inch (M5)](https://support.apple.com/en-us/125407), [iPad Pro 13-inch (M4)](https://support.apple.com/en-us/119891)                                                                                                                                                                                                                                                                                                                                    | 2752 × 2064              | 120        |

### iPad window targets

The mobile XML keeps all landscape panel modes above and adds the targets below.
Each row maps to the device names in the preceding table; XML blocks repeat the
device names. Sizes are physical pixels, with even dimensions. Portrait retains
the panel's 60/120 Hz rates. Split and Stage Manager targets use **60 Hz**.

| Landscape panel | Portrait    | Split 1/2   | Split 2/3   | Split 1/3  | Stage Manager half tile |
| --------------- | ----------- | ----------- | ----------- | ---------- | ----------------------- |
| 2048 × 1536     | 1536 × 2048 | 1014 × 1536 | 1352 × 1536 | 676 × 1536 | 1014 × 1290             |
| 2160 × 1620     | 1620 × 2160 | 1070 × 1620 | 1426 × 1620 | 712 × 1620 | 1070 × 1374             |
| 2224 × 1668     | 1668 × 2224 | 1102 × 1668 | 1468 × 1668 | 734 × 1668 | 1102 × 1422             |
| 2266 × 1488     | 1488 × 2266 | 1122 × 1488 | 1496 × 1488 | 748 × 1488 | 1122 × 1242             |
| 2360 × 1640     | 1640 × 2360 | 1170 × 1640 | 1560 × 1640 | 780 × 1640 | 1170 × 1394             |
| 2388 × 1668     | 1668 × 2388 | 1184 × 1668 | 1578 × 1668 | 788 × 1668 | 1184 × 1422             |
| 2420 × 1668     | 1668 × 2420 | 1200 × 1668 | 1600 × 1668 | 800 × 1668 | 1200 × 1422             |
| 2732 × 2048     | 2048 × 2732 | 1356 × 2048 | 1808 × 2048 | 904 × 2048 | 1356 × 1802             |
| 2752 × 2064     | 2064 × 2752 | 1366 × 2064 | 1820 × 2064 | 910 × 2064 | 1366 × 1818             |

Split targets divide the landscape width after a 20-pixel (10-point) gap, round
down to even, and retain the panel height. The half tiles were measured at 1014
× 1536 on mini 5/iPadOS 26 and 1366 × 2064 on Pro 13/iPadOS 27. The other
fractions are representative targets, not claims of fixed system window sizes.
Decorations, OS version and display zoom can change the actual bounds.
Dock-visible Stage Manager half tiles use the half-width target and reserve 246
pixels (123 points) vertically. Measurements on mini 5 (1014 × 1290) and Pro 13
(1366 × 1818) support this representative target. Other geometries are derived,
not individually measured or Apple-defined presets.

The catalog also includes 750 × 972 (small Stage Manager, measured on mini 5 and
Pro 13), 1280 × 1200 (the audit's medium window fixture) and 750 × 1706 (Pro 13
Slide Over). All use 60 Hz. Other widths, heights and portrait split
arrangements select the closest listed mode. Aspect fill scales proportionally
and crops edges when aspects differ; 1080p can crop substantially in a narrow
portrait window. It never stretches.

The **90-mode budget** retains 36 native landscape combinations and two 1080p
combinations, then adds 52 window combinations. Trade-offs:

- Remove all 36 optional half-size combinations; iOS never offered that preset.
- Keep 120 Hz for full-panel ProMotion and 1080p; window-specific modes use 60
  Hz.
- Prefer measured Dock-visible half tiles over estimated three-quarter sizes.
  Use representative sizes for continuous resizing, portrait splits and other
  Stage Manager sizes. No finite list can cover every window pixel size.
- Keep the older mixed-client sample unchanged. It lacks these window modes;
  iPhone/iPad users need the mobile file, not the combined file.

## Sample coverage and limits

All five files target MTT VDD 25.7.23 and select the GPU automatically. Each
header gives its exact count and the **90-mode budget**. The
[setup guide's file table](HOST_SETUP.md#pick-your-file) lists their counts.
`mac-builtin.xml` covers every built-in Mac panel above at native and even half
size (26 modes); `mac-apple-displays.xml` covers the Apple external table (10
modes). `iphone-ipad.xml` covers every mobile native row, both 1080p rates and
the window targets above (90 modes). The Mac files retain their half-size modes;
the mobile file spends those entries on usable window shapes.

### Default for mixed clients

[all-glimmer-clients.xml](vdd/all-glimmer-clients.xml) preserves the original
sample's mode list. It has **90 distinct width × height × refresh
combinations**, in **51 resolution entries**. One entry holds several
`<refresh_rate>` children. The empty `<global />` is deliberate:
`<g_refresh_rate>` adds that rate to every resolution and does not deduplicate a
rate already present locally.

The mode budget prioritizes every named Apple hardware native and Mac Balanced
request, including 60/120 Hz where the same size is shared or the screen caps
the rate. It also keeps 48/50 Hz for MacBook Pro and Pro Display XDR
fixed-refresh use. The remaining standard modes are:

| Sizes                                                     | Refresh rates in the sample |
| --------------------------------------------------------- | --------------------------- |
| 1280 × 720, 2560 × 1440, 3840 × 2160                      | 60, 120, 240                |
| 1920 × 1080                                               | 30, 60, 120, 240            |
| 1280 × 800, 1920 × 1200, 2560 × 1600, 3840 × 2400 (16:10) | 60                          |
| 3440 × 1440, 5120 × 2160 (21:9 class)                     | 60                          |
| 3840 × 1080, 5120 × 1440, 7680 × 2160 (32:9)              | 60                          |
| 7680 × 4320 (8K 16:9)                                     | 60                          |

A finite file cannot cover Mac Custom's arbitrary integer dimensions and FPS,
every external display, or future devices. Choosing an unlisted Custom value
still needs a matching PC mode. Apollo creates modes on demand, subject to the
same encoder limitations.

### Standard external displays

[standard-external.xml](vdd/standard-external.xml) spends its 90 modes on the
following Custom sizes. Common gaming sizes get the widest refresh selection;
large and less common sizes get fewer rates. These are selected virtual modes,
not a claim that every physical monitor supports each combination.

| Aspect class | Sizes                                             | Rates (Hz)                      |
| ------------ | ------------------------------------------------- | ------------------------------- |
| 16:9         | 1280 × 720, 1920 × 1080, 2560 × 1440, 3840 × 2160 | 60, 75, 100, 120, 144, 165, 240 |
| 16:9         | 1600 × 900                                        | 60, 75                          |
| 16:9         | 5120 × 2880, 7680 × 4320                          | 60, 120                         |
| 16:9         | 5760 × 3240                                       | 60                              |
| 16:10        | 1280 × 800, 1680 × 1050                           | 60, 75                          |
| 16:10        | 1920 × 1200                                       | 60, 75, 120                     |
| 16:10        | 2560 × 1600                                       | 60, 120, 144, 165               |
| 16:10        | 2880 × 1800, 3840 × 2400                          | 60, 120                         |
| 16:10        | 5120 × 3200, 6400 × 4000                          | 60                              |
| 21:9         | 2560 × 1080, 3440 × 1440                          | 60, 75, 100, 120, 144, 165, 240 |
| 21:9         | 3840 × 1600                                       | 60, 100, 120, 144, 165          |
| 21:9         | 5120 × 2160                                       | 60, 120                         |
| 21:9         | 6880 × 2880, 7680 × 3200                          | 60                              |
| 32:9         | 2560 × 720                                        | 60, 120                         |
| 32:9         | 3840 × 1080                                       | 60, 120, 144                    |
| 32:9         | 5120 × 1440, 7680 × 2160                          | 60, 120, 144, 165, 240          |

The budget leaves out other rates at the sizes above, including 75/100 Hz on
32:9 displays, 240 Hz at 3840 × 1600 and most high-refresh 16:10 modes. It also
omits 30/48/50/72/90/200 Hz throughout. 8K stops at 120 Hz because 144 Hz and
above overflow the tagged driver's timing arithmetic, not because of the mode
budget. Sizes beyond Glimmer's 7680 × 4320 bounds, including 7680 × 4800, cannot
be selected in Mac Custom. The driver itself publishes no fixed maximum size.

### Why each file stops at 90 modes

The target is the driver in
[MTT VDD release 25.7.23](https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/tag/25.7.23),
not the moving `master` branch. The
[tagged XML](https://github.com/VirtualDrivers/Virtual-Display-Driver/blob/25.7.23/Virtual%20Display%20Driver%20%28HDR%29/vdd_settings.xml)
separates `logging`, `colour`, `cursor` and `edid`; the
[24.10.27 sample](https://github.com/VirtualDrivers/Virtual-Display-Driver/blob/24.10.27/Virtual%20Display%20Driver%20%28HDR%29/vdd_settings.xml)
used `options`. Both support multiple refresh children. The
[configuration wiki](https://github.com/VirtualDrivers/Virtual-Display-Driver/wiki/How-to-configure-the-driver)
explains global rates, but its older `options` example is not the target schema.

There is no fixed mode-count cap in the tagged XML loader: it collects a vector
and sizes callback buffers from its length. That does not mean a large list
works. In
[upstream issue 254](https://github.com/VirtualDrivers/Virtual-Display-Driver/issues/254),
108 modes failed and 96 worked; a driver developer suggested documenting 96. In
[issue 157](https://github.com/VirtualDrivers/Virtual-Display-Driver/issues/157#issuecomment-2796544498),
a project member reported trouble above roughly 90 modes. These are practical
reports, not a documented universal Windows limit. Neither issue establishes a
fix in 25.7.23. Every sample uses a conservative budget of **90 modes**, which
still needs a Windows installation check.

### What the default file leaves out

- The iOS 27.1 Duo Simulator inner mode, 2852 × 2006 @ 60. The published Duo
  hardware sizes remain in both files.
- iPhone/iPad half-size modes and MacBook Neo's half size. No current Glimmer
  preset requests them. All actual Mac Balanced sizes remain.
- Additional Custom rates: 24, 72, 90, 100, 144, 165 and 200 Hz throughout the
  catalog. 24 is also below Glimmer's 30 fps minimum. 48/50 remain only on the
  Apple displays above, and 30 remains only at 1080p.
- Intermediate standard sizes such as 1600 × 900, 1680 × 1050, 2880 × 1800, 2560
  × 1080, 3840 × 1600 and 2560 × 720.
- Larger optional sizes such as 5760 × 3240, 5120 × 3200, 6400 × 4000, 6880 ×
  2880 and 7680 × 3200. The 7680 × 4800 extra also exceeds Glimmer's maximum
  height.
- 120–240 Hz variants of the optional ultrawide sizes and 8K. The four Mac
  shortcuts retain 60/120/240, and mobile 1080p retains 60/120.

The device-specific samples recover many of these modes within their separate
budgets. Do not add global rates: they multiply the total. Follow the
[combining instructions](HOST_SETUP.md#combine-two-files) to select modes from
two samples, or use Apollo for arbitrary Custom requests.

### Dimension and refresh limits

The tagged loader does not enforce a maximum width, height or refresh. Glimmer
accepts up to 7680 × 4320 at 240 fps, but a PC may not encode that combination.
The
[tagged driver](https://github.com/VirtualDrivers/Virtual-Display-Driver/blob/25.7.23/Virtual%20Display%20Driver%20%28HDR%29/MttVDD/Driver.cpp)
also uses 32-bit unsigned intermediate arithmetic in `CreateTargetMode` and
`dispinfo`. For integer rates, the test keeps both `width * height * fps` and
`(height + 4)^2 * fps + 1000` at or below 4,294,967,295. For example, 8K at 144
Hz would overflow the first expression. All retained modes fit.

This arithmetic check is source-derived, not a published driver maximum or proof
of sustained encoding, capture or decoding at that rate.

### Installation and switching evidence

The tagged driver initializes the settings folder to `C:\VirtualDisplayDriver`,
then checks `HKLM\SOFTWARE\MikeTheTech\VirtualDisplayDriver\VDDPATH`. It loads
`vdd_settings.xml` there. With GPU name `default`, it reads `adapter.txt`;
absent a valid selection,
[AdapterOption.h](https://github.com/VirtualDrivers/Virtual-Display-Driver/blob/25.7.23/Common/Include/AdapterOption.h)
chooses the enumerated GPU with the most dedicated video memory. The release
notes specify the control app's **Reload Driver** action (`RELOAD_DRIVER`).

[Sunshine's configuration reference](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html)
defines the Windows `device_id` for `output_name`, display activation policies,
automatic resolution/refresh selection and restoration on disconnect.
[Apollo's repository](https://github.com/ClassicOldSong/Apollo) documents
SudoVDA's per-client virtual display and automatic mode matching; its
[FAQ](https://github.com/ClassicOldSong/Apollo/wiki/FAQ) documents **Always use
Virtual Display**, **Headless Mode** and first-use Windows display arrangement.

## Verification

[scripts/tests/test_vdd_settings.py](../scripts/tests/test_vdd_settings.py)
parses every sample, rejects duplicate blocks/modes and malformed mode entries,
checks header counts, the 90-mode budget and timing limits, and requires each
file's device table. The default still covers all listed Glimmer preset requests
and the common Custom shortcuts at 60/120/240 Hz. It runs with the other Python
unittests under `make check`. The table is explicit so a sample edit cannot
silently redefine expected modes.

This revision checks source and configuration coverage. It does not establish
Windows driver installation, GPU encoder acceptance, sustained frame delivery,
Mac-to-iPhone switching or display restoration on physical hardware.

Next: [install the sample and start a stream](HOST_SETUP.md).
