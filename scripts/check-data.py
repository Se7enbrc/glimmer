#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Validate structured data without adding runtime dependencies."""

import json
from pathlib import Path
import sys
import tomllib


def main():
    failed = False
    for name in sys.argv[2:]:
        try:
            with Path(name).open('rb') as stream:
                if sys.argv[1] == 'toml':
                    tomllib.load(stream)
                else:
                    json.load(stream)
        except (ValueError, OSError) as error:
            print(f'{name}: {error}', file=sys.stderr)
            failed = True
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
