#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Keep repository Python scripts runnable with only the standard library."""

import ast
from pathlib import Path
import subprocess
import sys


def violations(path, local_modules):
    tree = ast.parse(path.read_text(), filename=str(path))
    for node in ast.walk(tree):
        names = []
        if isinstance(node, ast.Import):
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            names = [node.module]
        for name in names:
            root = name.split('.')[0]
            if root not in sys.stdlib_module_names and root not in local_modules:
                yield f'{path}:{node.lineno}: {name} is not a standard-library or repository module'


def main():
    tracked = subprocess.check_output(['git', 'ls-files', '-z', '*.py']).decode().split('\0')
    local_modules = {Path(name).stem for name in tracked if name}
    local_modules.update(Path(name).parent.name for name in tracked if name.endswith('/__init__.py'))
    failed = False
    for name in sys.argv[1:]:
        for message in violations(Path(name), local_modules):
            print(message, file=sys.stderr)
            failed = True
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
