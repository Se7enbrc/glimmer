# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Linux lint must load SourceKit rather than silently omit its rules."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LinuxLintTests(unittest.TestCase):
    def run_lint(self, with_sourcekit):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copy(ROOT / "scripts/lint-swift.sh", scripts / "lint-swift.sh")
            binary = root / "toolchain/bin"
            binary.mkdir(parents=True)
            library = root / "toolchain/lib/libsourcekitdInProc.so"
            library.parent.mkdir()
            if with_sourcekit:
                library.touch()
            commands = {
                "uname": "echo Linux",
                "swift": "exit 0",
                "readlink": 'printf "%s\\n" "$2"',
                "swiftlint": 'test "$LINUX_SOURCEKIT_LIB_PATH" = "$EXPECTED_LIBRARY" && test "$LD_LIBRARY_PATH" = "$EXPECTED_RUNTIME"',
            }
            for name, body in commands.items():
                path = binary / name
                path.write_text(f"#!/bin/bash\nset -eu\n{body}\n")
                path.chmod(0o755)
            env = dict(os.environ, PATH=f"{binary}:/usr/bin:/bin",
                       EXPECTED_LIBRARY=str(library),
                       EXPECTED_RUNTIME=str(library.parent / "swift/linux"))
            for key in ("LINUX_SOURCEKIT_LIB_PATH", "LD_LIBRARY_PATH"):
                env.pop(key, None)
            return subprocess.run(["bash", str(scripts / "lint-swift.sh"), "lint", "--strict"],
                                  env=env, capture_output=True).returncode

    def test_sourcekit_and_runtime_are_selected_from_active_toolchain(self):
        self.assertEqual(self.run_lint(True), 0)

    def test_missing_sourcekit_stops_lint(self):
        self.assertNotEqual(self.run_lint(False), 0)
