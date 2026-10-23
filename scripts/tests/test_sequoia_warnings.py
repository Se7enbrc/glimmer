# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""The independent Sequoia build must receive the CI compiler warning policy."""

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SequoiaWarningTests(unittest.TestCase):
    def test_build_for_testing_receives_warning_policy_and_preserves_failure(self):
        source = (ROOT / ".github/workflows/verify.yml").read_text()
        job = source.split("  sequoia-build:\n", 1)[1].split("  sequoia:\n", 1)[0]
        step = job.split("      - name: Build the unit tests for macOS 15.7\n", 1)[1]
        shell = textwrap.dedent(step.split("        run: |\n", 1)[1].split("      - name:", 1)[0])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            make = root / "make"
            make.write_text('''#!/bin/bash
[ "$1" = test-build ] || exit 99
cat "${XCODE_XCCONFIG_FILE:-missing}" > "$RUNNER_TEMP/observed.xcconfig"
exit 65
''')
            make.chmod(0o755)
            env = {key: value for key, value in os.environ.items() if key != "XCODE_XCCONFIG_FILE"}
            env.update(PATH=f"{root}:/usr/bin:/bin", RUNNER_TEMP=str(root))
            result = subprocess.run(["/bin/bash", "-euo", "pipefail", "-c", shell],
                                    cwd=root, env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 65, result.stderr)
            config = (root / "observed.xcconfig").read_text()
            self.assertIn("SWIFT_TREAT_WARNINGS_AS_ERRORS = YES", config)
            self.assertIn("GCC_TREAT_WARNINGS_AS_ERRORS = YES", config)
            self.assertFalse((root / "sequoia-tests.tgz").exists())
