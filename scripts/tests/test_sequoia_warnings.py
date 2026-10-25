# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Both macOS runs must share a build with the CI compiler warning policy."""

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
        job = source.split("  verify:\n", 1)[1].split("  ios:\n", 1)[0]
        prepare = job.split("      - name: Prepare verification\n", 1)[1]
        prepare = prepare.split("        run: |\n", 1)[1].split("      - name:", 1)[0]
        config = prepare[prepare.index('          XCODE_XCCONFIG_FILE='):]
        step = job.split("      - name: Build the shared Mac test products\n", 1)[1]
        build = step.split("        run: |\n", 1)[1].split("      - name:", 1)[0]
        shell = textwrap.dedent(config) + 'export XCODE_XCCONFIG_FILE\n' + textwrap.dedent(build)
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
            env.update(PATH=f"{root}:/usr/bin:/bin", RUNNER_TEMP=str(root), GITHUB_ENV=str(root / "env"))
            result = subprocess.run(["/bin/bash", "-euo", "pipefail", "-c", shell],
                                    cwd=root, env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 65, result.stderr)
            config = (root / "observed.xcconfig").read_text()
            self.assertIn("SWIFT_TREAT_WARNINGS_AS_ERRORS = YES", config)
            self.assertIn("GCC_TREAT_WARNINGS_AS_ERRORS = YES", config)
            self.assertFalse((root / "sequoia-tests.tgz").exists())
