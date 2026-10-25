# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Git fixtures must never inherit a hook's repository or user configuration."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from fixture_git import FixtureTestCase
from unittest.mock import patch

import test_release_candidate_cut


def snapshot(root):
    return {str(path.relative_to(root)): path.read_bytes()
            for path in root.rglob('*') if path.is_file()}


class GitIsolationTests(FixtureTestCase):
    def test_candidate_suite_does_not_touch_the_hook_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            decoy = root / 'decoy'
            decoy.mkdir()
            clean = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            clean.update(HOME=str(root), GIT_CONFIG_GLOBAL=str(root / 'empty'), GIT_CONFIG_NOSYSTEM='1',
                         GIT_ALLOW_PROTOCOL='file')
            subprocess.run(['git', 'init', '-q', str(decoy)], env=clean, check=True)
            before = snapshot(decoy)
            poison = dict(clean, GIT_DIR=str(decoy / '.git'), GIT_WORK_TREE=str(decoy),
                          GIT_INDEX_FILE=str(decoy / '.git/index'), GIT_PREFIX='poison/',
                          GIT_QUARANTINE_PATH=str(decoy / '.git/objects'), GIT_CONFIG_COUNT='1',
                          GIT_CONFIG_KEY_0='remote.origin.url', GIT_CONFIG_VALUE_0='https://invalid.test/repo')
            suite = unittest.defaultTestLoader.loadTestsFromTestCase(test_release_candidate_cut.ReleaseCandidateCutTests)
            result = unittest.TestResult()
            with patch.dict(os.environ, poison, clear=True):
                suite.run(result)
            self.assertEqual(snapshot(decoy), before, 'hook repository changed')
            self.assertTrue(result.wasSuccessful(), result.errors + result.failures)
