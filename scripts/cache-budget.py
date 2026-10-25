#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Keep optional cache uploads below the free repository storage allowance."""

import json
import os
from pathlib import Path
import subprocess

ENTRY_LIMIT = 512 * 1024**2
REPOSITORY_LIMIT = 5 * 1024**3


def admitted(ref, event, entry_bytes, repository_bytes):
    return (ref in ('refs/heads/main', 'refs/heads/release-candidate')
            and event in ('push', 'workflow_dispatch')
            and 0 < entry_bytes <= ENTRY_LIMIT
            and 0 <= repository_bytes < REPOSITORY_LIMIT)


def cache_size(paths):
    total = 0
    for path in paths:
        if path.is_symlink():
            raise ValueError('cache root must not be a symlink')
        if not path.exists():
            continue
        if not path.is_dir():
            raise ValueError('cache root must be a directory')
        def fail(error):
            raise error
        for directory, _, names in os.walk(path, onerror=fail):
            for name in names:
                total += (Path(directory) / name).lstat().st_size
    return total


def main():
    ref, event = os.environ.get('GITHUB_REF'), os.environ.get('GITHUB_EVENT_NAME')
    if not admitted(ref, event, 1, 0):
        print('save=false')
        return
    try:
        paths = [Path(os.path.expanduser(line)) for line in os.environ['CACHE_PATHS'].splitlines() if line]
        size = cache_size(paths)
        result = subprocess.run(['gh', 'api', f'repos/{os.environ["GITHUB_REPOSITORY"]}/actions/cache/usage'],
                                check=True, capture_output=True, text=True, timeout=30)
        used = json.loads(result.stdout)['active_caches_size_in_bytes']
        if type(used) is not int:
            raise ValueError('invalid usage')
        save = admitted(ref, event, size, used)
        print(f'bytes={size}\nrepository-bytes={used}\nsave={str(save).lower()}')
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        print('save=false')


if __name__ == '__main__':
    main()
