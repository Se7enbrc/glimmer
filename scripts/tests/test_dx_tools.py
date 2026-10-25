# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Developer commands must stay unsigned and use isolated compiler products."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

from fixture_git import FixtureTestCase

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('imports', ROOT / 'scripts/check-python-imports.py')
IMPORTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMPORTS)


class DeveloperToolsTests(FixtureTestCase):
    def test_default_is_help_without_signing_or_building(self):
        result = subprocess.run(['make', '-n'], cwd=ROOT, capture_output=True, text=True, check=True)
        self.assertIn('Develop', result.stdout)
        for command in ('security ', 'codesign ', 'notarytool ', 'xcodebuild '):
            self.assertNotIn(command, result.stdout)

    def test_signing_targets_are_not_available_locally(self):
        for target in ('codesign-setup', 'sparkle-keys', 'sign-bundle', 'release-publish', 'brew-bump'):
            result = subprocess.run(['make', '-n', target], cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, target)
            self.assertNotIn('security ', result.stdout)

    def test_import_guard_rejects_external_imports_in_nested_scopes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'example.py'
            path.write_text('import json\nfrom pathlib import Path\ndef load():\n    import requests\n')
            errors = list(IMPORTS.violations(path, set()))
            self.assertEqual(len(errors), 1)
            self.assertIn(':4: requests', errors[0])
            path.write_text('from release_validation import validate_feed\n')
            self.assertEqual(list(IMPORTS.violations(path, {'release_validation'})), [])


if __name__ == '__main__':
    unittest.main()
