#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Download only a named artifact from this upstream release run."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile
from release_artifact import identity


def check_metadata(data, kind, artifact, attempt):
    expected = identity(attempt)
    name = f'{kind}-{expected["GITHUB_RUN_ID"]}-{attempt}-{expected["EXPECTED_SHA"]}'
    run = data.get('workflow_run', {})
    if (str(data.get('id')) != artifact or data.get('name') != name or data.get('expired') is not False
            or str(run.get('id')) != expected['GITHUB_RUN_ID'] or run.get('head_sha') != expected['EXPECTED_SHA']):
        raise ValueError('artifact does not belong to the approved source, run and producing attempt')


def download(kind, artifact, attempt):
    if not re.fullmatch('[1-9][0-9]*', artifact):
        raise ValueError('artifact ID missing')
    endpoint = f'repos/Se7enbrc/glimmer/actions/artifacts/{artifact}'
    response = subprocess.run(['gh', 'api', endpoint], capture_output=True, text=True, check=True, timeout=60)
    check_metadata(json.loads(response.stdout), kind, artifact, attempt)
    root = Path(os.environ['RUNNER_TEMP']) / kind
    root.mkdir()
    with tempfile.TemporaryFile() as payload:
        subprocess.run(['gh', 'api', endpoint + '/zip'], stdout=payload, stderr=subprocess.PIPE,
                       check=True, timeout=180)
        payload.seek(0)
        with zipfile.ZipFile(payload) as archive:
            names = archive.namelist()
            if len(names) != len(set(names)) or any(Path(name).name != name for name in names):
                raise ValueError('unexpected artifact container paths')
            for entry in archive.infolist():
                if entry.is_dir() or (entry.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError('unexpected artifact container entry')
                with archive.open(entry) as data, (root / entry.filename).open('xb') as output:
                    shutil.copyfileobj(data, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kind', choices=('unsigned', 'signed'))
    parser.add_argument('artifact')
    parser.add_argument('attempt')
    args = parser.parse_args()
    try:
        download(args.kind, args.artifact, args.attempt)
    except (ValueError, OSError, KeyError, subprocess.SubprocessError, zipfile.BadZipFile):
        parser.exit(1, 'ERR: release artifact download or identity validation failed\n')


if __name__ == '__main__':
    main()
