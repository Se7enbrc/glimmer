# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-spdx.sh"


class LicenseNoticeTests(unittest.TestCase):
    def run_check(self, source):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copyfile(SCRIPT, root / "scripts/check-spdx.sh")
            (root / "present.swift").write_text(source)
            command = root / "git"
            command.write_text("#!/bin/sh\nprintf '%s\\n' present.swift deleted.swift\n")
            command.chmod(0o755)
            return subprocess.run(
                ["bash", str(root / "scripts/check-spdx.sh")], capture_output=True, text=True,
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}"}, check=False)

    def test_unstaged_deletion_is_not_a_missing_license(self):
        result = self.run_check("// SPDX-License-Identifier: GPL-3.0-only\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_existing_unlicensed_source_still_fails(self):
        result = self.run_check("import Foundation\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing SPDX header: present.swift", result.stderr)
        self.assertNotIn("deleted.swift", result.stderr)
