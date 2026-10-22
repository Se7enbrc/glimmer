# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Keep the PC samples aligned with Glimmer's requests; see docs/VIRTUAL_DISPLAY_MODES.md."""

from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

SAMPLES = Path(__file__).resolve().parents[2] / "docs/vdd"
COMMON_RATES = (60, 120, 240)
MAX_MODES = 90  # Conservative initialization budget; see the reference.
# QualityCalculator.effectiveValuesForPreset and StreamQuality.hidpiSize/encodableSize.
# Native width/height, actual Balanced width/height, display rates (including fixed modes).
MAC_BUILTIN_MODES = (
    (2560, 1600, 1280, 800, (60,)),       # M1 Air; 13-inch M1/M2 Pro.
    (2560, 1664, 1280, 832, (60,)),       # 13-inch M2/M3/M4/M5 Air.
    (2880, 1864, 1440, 932, (60,)),       # 15-inch M2/M3/M4/M5 Air.
    (3024, 1964, 1512, 982, (48, 50, 60, 120)),  # 14-inch Pro.
    (3456, 2234, 1728, 1116, (48, 50, 60, 120)), # 16-inch Pro; never 1117.
    (4480, 2520, 2240, 1260, (60,)),      # M1/M3/M4 iMac.
    (2408, 1506, 2408, 1506, (60,)),      # Neo: half width is below 1280.
)
APPLE_DISPLAY_MODES = (
    (5120, 2880, 2560, 1440, (60, 120)),  # Studio Display / Studio Display XDR.
    (6016, 3384, 3008, 1692, (48, 50, 60)), # Pro Display XDR.
)
# StreamProfile.resolve rounds landscape nativeBounds down with StreamQuality.encodableSize.
# 120 fps profiles cap to the screen maximum; 60 covers shared sizes and capped screens.
MOBILE_MODES = (
    (1334, 750, (60,)),          # SE 2/3.
    (1792, 828, (60,)),          # 11.
    (2340, 1080, (60,)),         # 12/13 mini.
    (2436, 1124, (60,)),         # 11 Pro.
    (2532, 1170, (60, 120)),     # 12/12 Pro/13/13 Pro/14/16e/17e.
    (2556, 1178, (60, 120)),     # 14 Pro/15/15 Pro/16.
    (2622, 1206, (60, 120)),     # 16 Pro/17/17 Pro/18 Pro.
    (2688, 1242, (60,)),         # 11 Pro Max.
    (2736, 1260, (60, 120)),     # Air.
    (2778, 1284, (60, 120)),     # 12 Pro Max/13 Pro Max/14 Plus.
    (2796, 1290, (60, 120)),     # 14 Pro Max/15 Plus/15 Pro Max/16 Plus.
    (2868, 1320, (60, 120)),     # 16/17/18 Pro Max.
    (2048, 1536, (60,)),        # iPad mini 5.
    (2160, 1620, (60,)),        # iPad 8/9.
    (2224, 1668, (60,)),        # iPad Air 3.
    (2266, 1488, (60,)),        # iPad mini 6/A17 Pro.
    (2360, 1640, (60,)),        # iPad 10/A16; Air 4/5 and 11-inch M2/M3/M4.
    (2388, 1668, (60, 120)),    # iPad Pro 11-inch 1/2/3/4.
    (2420, 1668, (60, 120)),    # iPad Pro 11-inch M4/M5.
    (2732, 2048, (60, 120)),    # iPad Pro 12.9-inch 3/4/5/6; Air 13-inch M2/M3/M4.
    (2752, 2064, (60, 120)),    # iPad Pro 13-inch M4/M5.
    (2670, 1878, (60, 120)),    # iPhone Duo open, iOS 27.
    (2034, 1398, (60, 120)),    # iPhone Duo cover, iOS 27.
)

STANDARD_MODES = (
    (1920, 1080, (60, 75, 100, 120, 144, 165, 240)),
    (1280, 720, (60, 75, 100, 120, 144, 165, 240)),
    (1600, 900, (60, 75)),
    (2560, 1440, (60, 75, 100, 120, 144, 165, 240)),
    (3840, 2160, (60, 75, 100, 120, 144, 165, 240)),
    (5120, 2880, (60, 120)),
    (5760, 3240, (60,)),
    (7680, 4320, (60, 120)),
    (1280, 800, (60, 75)),
    (1680, 1050, (60, 75)),
    (1920, 1200, (60, 75, 120)),
    (2560, 1600, (60, 120, 144, 165)),
    (2880, 1800, (60, 120)),
    (3840, 2400, (60, 120)),
    (5120, 3200, (60,)),
    (6400, 4000, (60,)),
    (2560, 1080, (60, 75, 100, 120, 144, 165, 240)),
    (3440, 1440, (60, 75, 100, 120, 144, 165, 240)),
    (3840, 1600, (60, 100, 120, 144, 165)),
    (5120, 2160, (60, 120)),
    (6880, 2880, (60,)),
    (7680, 3200, (60,)),
    (2560, 720, (60, 120)),
    (3840, 1080, (60, 120, 144)),
    (5120, 1440, (60, 120, 144, 165, 240)),
    (7680, 2160, (60, 120, 144, 165, 240)),
)


def panel_modes(rows, include_half=False):
    modes = set()
    for width, height, rates in rows:
        sizes = [(width, height)]
        if include_half:
            sizes.append((width // 2 & ~1, height // 2 & ~1))
        modes.update((w, h, fps) for w, h in sizes for fps in rates)
    return modes


class VirtualDisplaySettingsTests(unittest.TestCase):
    def read_modes(self, sample):
        root = ET.parse(sample).getroot()
        self.assertEqual(root.tag, "vdd_settings")
        self.assertEqual([child.tag for child in root],
                         ["monitors", "gpu", "global", "resolutions", "logging", "colour", "cursor", "edid"])
        self.assertEqual(root.findtext("monitors/count"), "1")
        self.assertEqual(root.findtext("gpu/friendlyname"), "default")
        self.assertEqual(list(root.find("global")), [])
        modes, sizes = set(), set()
        for entry in root.find("resolutions"):
            self.assertEqual(entry.tag, "resolution")
            self.assertFalse(entry.attrib)
            tags = [child.tag for child in entry]
            self.assertGreaterEqual(len(tags), 3)
            self.assertEqual(tags[:2], ["width", "height"])
            self.assertTrue(all(tag == "refresh_rate" for tag in tags[2:]))
            for child in entry:
                self.assertFalse(child.attrib)
                self.assertEqual(list(child), [])
                self.assertRegex(child.text or "", r"^[1-9][0-9]*$")
            width, height = int(entry[0].text), int(entry[1].text)
            self.assertTrue(0 < height <= width <= 7680 and height <= 4320)
            self.assertEqual((width % 2, height % 2), (0, 0))
            self.assertNotIn((width, height), sizes, "duplicate resolution block")
            sizes.add((width, height))
            for rate in entry[2:]:
                fps = int(rate.text)
                self.assertTrue(24 <= fps <= 240)
                mode = (width, height, fps)
                self.assertNotIn(mode, modes, "duplicate mode")
                modes.add(mode)
                self.assertLessEqual(width * height * fps, 2**32 - 1)
                self.assertLessEqual((height + 4)**2 * fps + 1000, 2**32 - 1)
        self.assertLessEqual(len(modes), MAX_MODES)
        header = re.search(r"<!-- (\d+) modes; budget: (\d+) modes\.", sample.read_text().split("<vdd_settings>", 1)[0])
        self.assertIsNotNone(header, "missing mode count and budget in header")
        self.assertEqual(int(header[1]), len(modes))
        self.assertEqual(int(header[2]), MAX_MODES)
        return modes

    def test_all_samples_and_device_coverage(self):
        builtin = [(w, h, rates) for w, h, _, _, rates in MAC_BUILTIN_MODES]
        displays = [(w, h, rates) for w, h, _, _, rates in APPLE_DISPLAY_MODES]
        required = panel_modes(MOBILE_MODES)
        for width, height, half_width, half_height, rates in MAC_BUILTIN_MODES + APPLE_DISPLAY_MODES:
            required.update((w, h, fps) for w, h in ((width, height), (half_width, half_height)) for fps in rates)
        required.update((w, h, fps) for w, h in ((1280, 720), (1920, 1080), (2560, 1440), (3840, 2160))
                        for fps in COMMON_RATES)
        expected = {
            "all-glimmer-clients.xml": required,
            "mac-builtin.xml": panel_modes(builtin, include_half=True),
            "mac-apple-displays.xml": panel_modes(displays, include_half=True),
            "iphone-ipad.xml": panel_modes(MOBILE_MODES, include_half=True)
                               | {(1920, 1080, 60), (1920, 1080, 120)},
            "standard-external.xml": panel_modes(STANDARD_MODES),
        }
        self.assertEqual({path.name for path in SAMPLES.glob("*.xml")}, set(expected))
        for name, required_modes in expected.items():
            with self.subTest(sample=name):
                modes = self.read_modes(SAMPLES / name)
                self.assertFalse(required_modes - modes,
                                 f"Missing modes: {sorted(required_modes - modes)}")
                if name != "all-glimmer-clients.xml":
                    self.assertEqual(modes, required_modes)
