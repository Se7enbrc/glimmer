#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Select compiler targets from local changes, conservatively including unknown build inputs."""

import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SHARED = ('GlimmerEngine/', 'Package.', 'Makefile', 'scripts/', '.github/workflows/', '.github/actions/')
MAC = ('Glimmer/', 'GlimmerTests/', 'Glimmer.xcodeproj/', 'LoginHelper/', 'helper/')
IOS = ('iOS/', 'EnginePackageTests/')


def targets(paths):
    selected = set()
    for path in paths:
        if path.endswith('.md'):
            continue
        if path.startswith(SHARED) or path.endswith(('.xcconfig', '.h')):
            selected.update(('mac', 'ios'))
        elif path.startswith(MAC):
            selected.add('mac')
        elif path.startswith(IOS):
            selected.add('ios')
    return sorted(selected)


def changed_paths():
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}

    def git(*args):
        return subprocess.check_output(['git', *args], cwd=ROOT, env=env, stderr=subprocess.DEVNULL).decode()

    try:
        try:
            base = git('rev-parse', '--verify', '@{upstream}').strip()
        except subprocess.CalledProcessError:
            base = git('merge-base', 'HEAD', 'origin/main').strip()
        return (git('diff', '--name-only', '-z', base).split('\0') +
                git('ls-files', '--others', '--exclude-standard', '-z').split('\0'))
    except (OSError, subprocess.SubprocessError):
        return ['Makefile']


if __name__ == '__main__':
    print(' '.join(targets(changed_paths())))
