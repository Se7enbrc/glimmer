# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Push checks compile every affected platform without running the full verification gate."""

import importlib.util
from pathlib import Path
import subprocess
import unittest

from fixture_git import FixtureTestCase

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('scope', ROOT / 'scripts/preflight-scope.py')
SCOPE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCOPE)


class PreflightScopeTests(FixtureTestCase):
    def test_native_and_shared_changes_select_their_consumers(self):
        for paths, expected in ((['Glimmer/AppModel.swift'], ['mac']), (['iOS/Glimmer/App.swift'], ['ios']),
                                (['GlimmerEngine/Session.swift'], ['ios', 'mac']),
                                (['scripts/ci-parity.sh'], ['ios', 'mac']),
                                (['docs/CONTRIBUTING.md'], []), ([], [])):
            with self.subTest(paths=paths):
                self.assertEqual(SCOPE.targets(paths), expected)

    def test_preflight_checks_hooks_and_fast_tests_without_full_verify(self):
        result = subprocess.run(['make', '-n', 'preflight'], cwd=ROOT, capture_output=True, text=True, check=True)
        self.assertIn('hk check --all', result.stdout)
        self.assertIn('scripts/test-scripts.py fast', result.stdout)
        self.assertIn('scripts/ci-parity.sh --changed', result.stdout)
        self.assertNotIn('xcodebuild test ', result.stdout)
        self.assertNotIn('test-asan', result.stdout)

    def test_guarded_hook_never_launches_mise_in_an_old_worktree(self):
        documentation = (ROOT / 'docs/CONTRIBUTING.md').read_text()
        guard = documentation.split('"test -f hk.pkl', 1)[1].split('\n', 1)[0]
        command = ('test -f hk.pkl' + guard).removesuffix('"')
        command = command.replace('\\"', '"').replace('\\${HK:-1}', '${HK:-1}').replace('$event', 'pre-commit')
        for files, status in (([], 0), (['hk.pkl'], 0), (['hk.pkl', 'mise.toml'], 127)):
            with self.subTest(files=files):
                for name in files:
                    Path(name).touch()
                result = subprocess.run(['/bin/sh', '-c', command], env={'PATH': '/nonexistent'},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, status)
                if status == 0:
                    self.assertEqual(result.stdout + result.stderr, '')

    def test_markdown_hook_passes_filenames_after_the_option_delimiter(self):
        hook = (ROOT / 'hk.pkl').read_text()
        command = hook.split('check = "markdownlint ', 1)[1].split('"', 1)[0]
        source = Path('bad.md')
        source.write_text('#Missing heading space\n')
        result = subprocess.run(['markdownlint', *command.replace('{{files}}', str(source)).split()],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('MD018', result.stdout + result.stderr)
