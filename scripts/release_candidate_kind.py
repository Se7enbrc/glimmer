# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Candidate identity and the signed diagnostic marker share one strict contract."""

import argparse
from pathlib import Path
import plistlib
import re


def parse_tag(tag):
    match = re.fullmatch(r'([0-9]+\.[0-9]+\.[0-9]+)-rc\.([1-9][0-9]*)(-diag)?', tag)
    if match is None:
        raise ValueError('invalid candidate tag')
    return match[1], int(match[2]), bool(match[3])


def diagnostic_marker(info):
    value = info.get('GlimmerDiagnosticBuild', False)
    if type(value) is bool:
        return value
    if type(value) is str and value in ('YES', 'NO'):
        return value == 'YES'
    raise ValueError('invalid GlimmerDiagnosticBuild marker')


def validate_marker(info, tag):
    if diagnostic_marker(info) != parse_tag(tag)[2]:
        raise ValueError('bundle diagnostic marker differs from candidate tag')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tag')
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    try:
        validate_marker(plistlib.loads((args.app / 'Contents/Info.plist').read_bytes()), args.tag)
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f'ERR: {error}\n')


if __name__ == '__main__':
    main()
