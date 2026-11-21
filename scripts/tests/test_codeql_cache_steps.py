# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Cache maintenance must not launch the Swift extractor; compiler tracing stays intact."""

import os
from pathlib import Path
import signal
import subprocess
import tempfile
import textwrap
import unittest

from fixture_git import FixtureTestCase

ROOT = Path(__file__).resolve().parents[2]


class CodeQLCacheStepTests(FixtureTestCase):
    def test_maintenance_does_not_inherit_compiler_tracing(self):
        workflow = (ROOT / ".github/workflows/codeql.yml").read_text()
        for name in ("Key cached framework extraction", "Seed framework extraction", "Collect framework extraction"):
            with self.subTest(step=name):
                step = workflow.split(f"      - name: {name}\n", 1)[1].split("      - name:", 1)[0]
                self.assertIn('DYLD_INSERT_LIBRARIES: ""', step)

    def test_framework_archive_round_trip_excludes_checkout(self):
        workflow = (ROOT / ".github/workflows/codeql.yml").read_text()

        def step(name):
            return workflow.split(f"      - name: {name}\n", 1)[1].split("      - name:", 1)[0]

        collect = step("Collect framework extraction")
        condition = " ".join(collect.split())
        self.assertIn("github.event_name == 'push' || github.event_name == 'workflow_dispatch'", condition)
        self.assertIn("github.ref == 'refs/heads/main' || github.ref == 'refs/heads/release-candidate'", condition)
        self.assertIn("if: steps.collect.outcome == 'success'", step("Save framework extraction"))
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            trap = scratch / "codeql-databases/swift/trap/swift"
            workspace = "/Users/runner/work/glimmer/glimmer"
            frameworks = [Path(kind) / "Applications/Xcode.app/Module.trap" for kind in ("modules", "lazy_decls")]
            project = [Path(kind) / workspace[1:] / "Sources/File.trap" for kind in ("modules", "lazy_decls")]
            for path in frameworks + project:
                (trap / path).parent.mkdir(parents=True)
                (trap / path).write_text(str(path))
            env = dict(os.environ, RUNNER_TEMP=str(scratch), GITHUB_WORKSPACE=workspace)
            for operation in (collect, step("Seed framework extraction")):
                shell = textwrap.dedent(operation.split("        run: |\n", 1)[1])
                subprocess.run(["bash", "-eu", "-c", shell], env=env, check=True, capture_output=True)
                if operation == collect:
                    trap.rename(scratch / "original")
            for path in frameworks:
                self.assertEqual((trap / path).read_text(), str(path))
            for path in project:
                self.assertFalse((trap / path).exists())

    def test_non_swift_changes_report_swift_check_without_queueing_a_mac(self):
        workflow = (ROOT / ".github/workflows/codeql.yml").read_text()
        decision = workflow.split("  changes:\n", 1)[1].split("  analyze:\n", 1)[0]
        self.assertIn("runs-on: ubuntu-latest", decision)
        self.assertIn("needs: changes", workflow)
        self.assertIn("needs.changes.outputs.scan == 'true' && needs.changes.outputs.apple_runner", " ".join(workflow.split()))
        self.assertIn('test "$DECIDED" = success', workflow)
        self.assertIn("if: ${{ !cancelled() && github.event.action != 'closed' }}", workflow)

    def test_compiler_and_complete_extraction_gate_remain(self):
        wrapper = (ROOT / "scripts/codeql-swiftc.sh").read_text()
        self.assertIn('export DYLD_INSERT_LIBRARIES="$SEMMLE_PRELOAD_libtrace"', wrapper)
        workflow = (ROOT / ".github/workflows/codeql.yml").read_text()
        self.assertIn('make -j2 app helper-build CONFIG=Debug SWIFTC="$PWD/scripts/codeql-swiftc.sh"', workflow)
        self.assertIn("make ios-app CONFIG=Debug", workflow)
        self.assertIn("python3 scripts/codeql-coverage.py", workflow)
        self.assertIn("queries: security-extended", workflow)
        self.assertIn("SWIFT_ENABLE_COMPILE_CACHE = NO", workflow)
        self.assertIn("ARCHS = arm64", workflow)
        self.assertIn("ONLY_ACTIVE_ARCH = YES", workflow)


class CodeQLBuildTests(FixtureTestCase):
    def test_independent_builds_overlap_and_either_failure_blocks_analysis(self):
        workflow = (ROOT / ".github/workflows/codeql.yml").read_text()
        step = workflow.split("      - name: Build both apps, login item and privileged helper\n", 1)[1]
        shell = textwrap.dedent(step.split("        run: |\n", 1)[1].split("      #", 1)[0])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "iOS").mkdir()
            (root / "iOS/Makefile").touch()
            make = root / "make"
            make.write_text('''#!/bin/bash
set -eu
if [ "$1" = -j2 ] && [ "$2" = app ] && [ "$3" = helper-build ]; then
  printf 'ready\\n' > "$FIXTURE/ready"
  read -r reply < "$FIXTURE/reply"
  touch "$FIXTURE/mac-finished"
  exit "$MAC_STATUS"
fi
[ "$1" = ios-app ]
read -r ready < "$FIXTURE/ready"
printf 'ready\\n' > "$FIXTURE/reply"
touch "$FIXTURE/ios-finished"
exit "$IOS_STATUS"
''')
            make.chmod(0o755)
            for name in ("ready", "reply"):
                os.mkfifo(root / name)
            for mac, ios in ((0, 0), (65, 0), (0, 66), (65, 66)):
                with self.subTest(mac=mac, ios=ios):
                    env = dict(os.environ, PATH=f"{root}:/usr/bin:/bin", FIXTURE=str(root),
                               MAC_STATUS=str(mac), IOS_STATUS=str(ios))
                    process = subprocess.Popen(["bash", "-euo", "pipefail", "-c", shell], cwd=root,
                                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                               start_new_session=True)
                    try:
                        process.communicate(timeout=5)
                    finally:
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.communicate()
                    self.assertEqual(process.returncode == 0, mac == ios == 0)
                    for name in ("mac-finished", "ios-finished"):
                        self.assertTrue((root / name).exists())
                        (root / name).unlink()
