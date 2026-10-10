# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""The build comparison must notice any byte, mode or link change between two bundles."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "compare-builds.sh"


def bundle(root, payload=b"same bytes", mode=0o755, link="Versions/B/Sparkle"):
    app = root / "Fixture.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    binary = app / "Contents/MacOS/Fixture"
    binary.write_bytes(payload)
    binary.chmod(mode)
    os.symlink(link, app / "Contents/Current")
    return app


class CompareBuildsTests(unittest.TestCase):
    def compare(self, a, b):
        return subprocess.run([str(SCRIPT), str(a), str(b)], capture_output=True, text=True)

    def test_identical_bundles_pass(self):
        with tempfile.TemporaryDirectory() as one, tempfile.TemporaryDirectory() as two:
            result = self.compare(bundle(Path(one)), bundle(Path(two)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("identical", result.stdout)

    def test_changed_bytes_mode_or_link_fail(self):
        for change in ({"payload": b"other bytes"}, {"mode": 0o644}, {"link": "Versions/A/Sparkle"}):
            with tempfile.TemporaryDirectory() as one, tempfile.TemporaryDirectory() as two:
                result = self.compare(bundle(Path(one)), bundle(Path(two), **change))
                self.assertEqual(result.returncode, 1, change)
                self.assertIn("Contents/", result.stderr)


if __name__ == "__main__":
    unittest.main()
