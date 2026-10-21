#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Manual, exact-commit TestFlight build, verified handoff and internal-only upload."""

import argparse
import importlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import time
import zipfile

artifact = importlib.import_module('ios-testflight-artifact')
signing = importlib.import_module('ios-testflight-sign')


def toolchain():
    result = subprocess.run(['xcodebuild', '-version'], capture_output=True, text=True, check=True, timeout=30)
    if result.stdout.splitlines()[0] != 'Xcode 26.6':
        raise ValueError('TestFlight CI must use the verified Xcode 26.6 toolchain')
    return result.stdout.strip()


def gate(expected):
    artifact.require_dispatch()
    checks = importlib.import_module('release-checks').check(expected['EXPECTED_SHA'])
    output = Path(os.environ['RUNNER_TEMP']) / 'ios-testflight-checks.json'
    output.write_text(json.dumps(checks, sort_keys=True) + '\n')
    return checks


def archive(source, destination, expected):
    actual = subprocess.run(['git', '-C', str(source), 'rev-parse', 'HEAD'], capture_output=True,
                            text=True, check=True, timeout=30).stdout.strip()
    if actual != expected['EXPECTED_SHA'] or destination.exists():
        raise ValueError('source differs from the approved SHA or archive already exists')
    compiler = toolchain()
    derived = destination.parent / 'ios-testflight-derived'
    command = ['xcodebuild', '-project', str(source / 'iOS/Glimmer.xcodeproj'), '-scheme', 'Glimmer-iOS',
               '-configuration', 'Release', '-destination', 'generic/platform=iOS',
               '-derivedDataPath', str(derived), '-archivePath', str(destination),
               'CODE_SIGNING_ALLOWED=NO', 'DEBUG_INFORMATION_FORMAT=dwarf-with-dsym',
               'SWIFT_ACTIVE_COMPILATION_CONDITIONS=', 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES',
               'GCC_TREAT_WARNINGS_AS_ERRORS=YES', f"MARKETING_VERSION={expected['IOS_VERSION']}",
               f"CURRENT_PROJECT_VERSION={expected['IOS_BUILD_NUMBER']}", 'archive']
    log = destination.parent / 'ios-testflight-archive.log'
    with log.open('wb') as stream:
        subprocess.run(command, cwd=source, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=1800)
    artifact.validate_archive(destination, expected)
    (destination.parent / 'ios-testflight-toolchain.txt').write_text(compiler + '\n')


def check_metadata(data, expected, artifact_id):
    name = f"ios-unsigned-{expected['GITHUB_RUN_ID']}-{expected['GITHUB_RUN_ATTEMPT']}"
    run = data.get('workflow_run', {})
    if (str(data.get('id')) != artifact_id or data.get('name') != name or data.get('expired') is not False
            or str(run.get('id')) != expected['GITHUB_RUN_ID']
            or run.get('head_sha') != expected['TRUSTED_TOOLING_SHA']):
        raise ValueError('artifact must belong to this main workflow run and producing attempt')


def download(artifact_id, payload, expected):
    if not re.fullmatch(r'[1-9][0-9]*', artifact_id) or payload.exists():
        raise ValueError('invalid artifact ID or destination')
    endpoint = f'repos/{artifact.REPOSITORY}/actions/artifacts/{artifact_id}'
    metadata = subprocess.run(['gh', 'api', endpoint], check=True, capture_output=True, text=True, timeout=60)
    check_metadata(json.loads(metadata.stdout), expected, artifact_id)
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(['gh', 'api', endpoint + '/zip'], stdout=output, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 180
        try:
            while process.poll() is None:
                if os.fstat(output.fileno()).st_size > artifact.MAX_BYTES or time.monotonic() > deadline:
                    raise ValueError('artifact download exceeded its size or time limit')
                time.sleep(0.1)
            if process.returncode or os.fstat(output.fileno()).st_size > artifact.MAX_BYTES:
                raise ValueError('artifact download failed or exceeded its size limit')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
        output.seek(0)
        with zipfile.ZipFile(output) as bundle:
            entries = bundle.infolist()
            if (len(entries) != 2 or {e.filename for e in entries} != {'archive.zip', 'manifest.json'}
                    or sum(e.file_size for e in entries) > artifact.MAX_BYTES):
                raise ValueError('unexpected artifact container')
            payload.mkdir()
            for entry in entries:
                if entry.is_dir() or stat.S_IFMT(entry.external_attr >> 16) not in (0, stat.S_IFREG):
                    raise ValueError('artifact container must contain only regular files')
                with bundle.open(entry) as data, (payload / entry.filename).open('xb') as destination:
                    shutil.copyfileobj(data, destination)


def write_outputs(**values):
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for key, value in values.items():
            output.write(f'{key}={value}\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('inputs', 'gate', 'archive', 'seal', 'import', 'export', 'upload', 'cleanup'))
    parser.add_argument('--source', type=Path)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        if args.operation == 'cleanup':
            signing.cleanup()
            return
        expected = artifact.identity(attempt=os.environ.get('ARCHIVE_ATTEMPT'))
        artifact.require_dispatch()
        if args.operation == 'inputs':
            return
        if args.operation == 'gate':
            gate(expected)
        elif args.operation == 'archive':
            archive(args.source.resolve(), args.archive.resolve(), expected)
        elif args.operation == 'seal':
            manifest = artifact.seal(args.archive, args.output, expected)
            write_outputs(manifest=manifest, attempt=expected['GITHUB_RUN_ATTEMPT'])
        elif args.operation == 'import':
            download(os.environ['ARCHIVE_ARTIFACT_ID'], args.output, expected)
            artifact.import_archive(args.output, args.archive.parent, expected, os.environ['ARCHIVE_MANIFEST'])
        elif args.operation == 'export':
            toolchain()
            signing.export(args.archive, args.output, expected)
        elif args.operation == 'upload':
            signing.upload(args.output, expected)
    except ValueError as error:
        parser.exit(1, f'ERR: {str(error)[:240]}\n')
    except subprocess.CalledProcessError as error:
        # Tool arguments can contain credentials; never stringify a CalledProcessError.
        parser.exit(1, f'ERR: iOS TestFlight {args.operation} tool failed with exit code {error.returncode}\n')
    except (KeyError, TypeError, OSError, subprocess.SubprocessError, zipfile.BadZipFile):
        parser.exit(1, f'ERR: iOS TestFlight {args.operation} failed; no success is implied\n')


if __name__ == '__main__':
    main()
