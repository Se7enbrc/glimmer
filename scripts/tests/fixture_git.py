# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Keep every fixture, including its setup and children, outside the caller's Git state."""

from contextlib import chdir, contextmanager
from functools import cache
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


@cache
def developer_directory():
    if sys.platform != 'darwin' or os.environ.get('DEVELOPER_DIR'):
        return os.environ.get('DEVELOPER_DIR')
    path = Path(subprocess.check_output(['/usr/bin/xcrun', '--find', 'git'], text=True).strip())
    return str(path.parents[2]) if str(path).endswith('/usr/bin/git') else None


@contextmanager
def isolated_git():
    with tempfile.TemporaryDirectory(prefix='glimmer-fixture-') as directory:
        root = Path(directory).resolve()
        home = root / 'home'
        home.mkdir()
        config = home / 'gitconfig'
        config.touch()
        (home / 'runtime').mkdir(mode=0o700)
        env = {key: value for key, value in os.environ.items() if not key.startswith(('GIT_', 'XDG_'))}
        if developer_directory():
            env['DEVELOPER_DIR'] = developer_directory()
        env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / 'config'), XDG_CACHE_HOME=str(home / 'cache'),
                   XDG_DATA_HOME=str(home / 'data'), XDG_STATE_HOME=str(home / 'state'),
                   XDG_CONFIG_DIRS=str(home / 'config'), XDG_DATA_DIRS=str(home / 'data'),
                   XDG_RUNTIME_DIR=str(home / 'runtime'),
                   GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_SYSTEM=str(config), GIT_CONFIG_NOSYSTEM='1',
                   GIT_ALLOW_PROTOCOL='file', GIT_TERMINAL_PROMPT='0', GIT_CEILING_DIRECTORIES=str(root),
                   TMPDIR=str(root))
        with patch.dict(os.environ, env, clear=True), patch.object(tempfile, 'tempdir', str(root)), chdir(root):
            yield root


class FixtureTestCase(unittest.TestCase):
    def run(self, result=None):
        # setUp, cleanups and indirect production calls all see the same isolated state.
        with isolated_git():
            return super().run(result)


@contextmanager
def poisoned_hook():
    with isolated_git() as root:
        decoy = root / 'decoy'
        subprocess.run(['git', 'init', '-q', str(decoy)], check=True)

        def snapshot():
            return {str(path.relative_to(decoy)): path.read_bytes()
                    for path in decoy.rglob('*') if path.is_file()}

        before = snapshot()
        poison = dict(GIT_DIR=str(decoy / '.git'), GIT_WORK_TREE=str(decoy),
                      GIT_INDEX_FILE=str(decoy / '.git/index'), GIT_PREFIX='poison/',
                      GIT_QUARANTINE_PATH=str(decoy / '.git/objects'), GIT_CONFIG_COUNT='1',
                      GIT_CONFIG_KEY_0='remote.origin.url', GIT_CONFIG_VALUE_0='https://invalid.test/decoy',
                      GIT_ALTERNATE_OBJECT_DIRECTORIES=str(decoy / '.git/objects'))
        with patch.dict(os.environ, poison):
            yield
        if snapshot() != before:
            raise AssertionError('The script suite modified the hook repository')
