# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Isolation is established before setup, even with new Git environment variables."""

import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

from fixture_git import FixtureTestCase, isolated_git


class FixtureGitTests(FixtureTestCase):
    def test_unknown_git_variables_and_user_configuration_are_removed(self):
        with patch.dict(os.environ, GIT_FUTURE_VARIABLE='inherited', GIT_CONFIG_COUNT='9', XDG_UNKNOWN='inherited'), isolated_git() as root:
            self.assertNotIn('GIT_FUTURE_VARIABLE', os.environ)
            self.assertNotIn('GIT_CONFIG_COUNT', os.environ)
            self.assertNotIn('XDG_UNKNOWN', os.environ)
            for name in ('HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME', 'GIT_CONFIG_GLOBAL'):
                self.assertTrue(Path(os.environ[name]).is_relative_to(root), name)
            self.assertEqual(Path.cwd(), root)
            self.assertEqual(os.environ['GIT_CONFIG_NOSYSTEM'], '1')
            result = subprocess.run(['git', 'ls-remote', 'https://invalid.test/fixture'],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("transport 'https' not allowed", result.stderr)

    def test_empty_fixture_directory_cannot_discover_the_real_checkout(self):
        result = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
