#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Bind release handoffs to a producing run, attempt, source and exact bytes."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
from release_candidate_kind import parse_tag
import release_symbols


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def identity(attempt=None):
    values = {key: os.environ[key] for key in ('GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'EXPECTED_SHA', 'RC_TAG')}
    values['GITHUB_RUN_ATTEMPT'] = attempt or os.environ['GITHUB_RUN_ATTEMPT']
    if values['GITHUB_REPOSITORY'] != 'Se7enbrc/glimmer':
        raise ValueError('unexpected artifact repository')
    if not re.fullmatch('[0-9a-f]{40}', values['EXPECTED_SHA']):
        raise ValueError('invalid artifact source')
    parse_tag(values['RC_TAG'])
    for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT'):
        if not re.fullmatch('[1-9][0-9]*', values[key]):
            raise ValueError('invalid artifact run or attempt')
    if int(values['GITHUB_RUN_ATTEMPT']) > int(os.environ['GITHUB_RUN_ATTEMPT']):
        raise ValueError('artifact attempt is in the future')
    return values


def seal(root, kind):
    files = sorted(root.iterdir())
    if not files or any(not path.is_file() or path.is_symlink() for path in files):
        raise ValueError('artifact must contain only regular files')
    manifest = {'identity': identity(), 'kind': kind, 'hashes': {p.name: digest(p) for p in files}}
    path = root / 'manifest.json'
    path.write_text(json.dumps(manifest, sort_keys=True) + '\n')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'manifest={digest(path)}\nattempt={os.environ["GITHUB_RUN_ATTEMPT"]}\n')
    return manifest


def verify(root, kind, expected, attempt):
    if not attempt or not re.fullmatch('[1-9][0-9]*', attempt):
        raise ValueError('artifact producing attempt missing')
    if not re.fullmatch('[0-9a-f]{64}', expected) or digest(root / 'manifest.json') != expected:
        raise ValueError('artifact manifest digest mismatch')
    manifest = json.loads((root / 'manifest.json').read_text())
    if manifest.get('identity') != identity(attempt) or manifest.get('kind') != kind:
        raise ValueError('artifact identity mismatch')
    hashes = manifest.get('hashes', {})
    if not hashes or set(hashes) | {'manifest.json'} != {p.name for p in root.iterdir()}:
        raise ValueError('artifact file set mismatch')
    for name, value in hashes.items():
        path = root / name
        if Path(name).name != name or path.is_symlink() or not path.is_file() or digest(path) != value:
            raise ValueError('artifact payload digest mismatch')
    return manifest


def unpack(archive, destination):
    destination = destination.resolve()
    if destination.exists():
        raise ValueError('unsigned destination already exists')
    with tarfile.open(archive, 'r:gz') as source:
        entries = source.getmembers()
        names = set()
        links = set()
        for entry in entries:
            path = PurePosixPath(entry.name)
            if (path.is_absolute() or '..' in path.parts or not path.parts
                    or path.parts[0] != 'Glimmer.app' or str(path) in names):
                raise ValueError('unsafe unsigned archive path')
            names.add(str(path))
            if not (entry.isfile() or entry.isdir() or entry.issym()) or entry.mode & 0o7000:
                raise ValueError('unsafe unsigned archive entry')
            if entry.issym():
                target = os.path.normpath(str(path.parent / entry.linkname))
                if not target.startswith('Glimmer.app/') or PurePosixPath(entry.linkname).is_absolute():
                    raise ValueError('unsigned symlink escapes bundle')
                links.add(str(path))
        for entry in entries:
            if any(str(parent) in links for parent in PurePosixPath(entry.name).parents):
                raise ValueError('unsigned entry descends through a symlink')
        destination.mkdir(parents=True)
        # Write files before links and never ask tar to restore ownership or special modes.
        for entry in entries:
            path = destination / entry.name
            path.parent.mkdir(parents=True, exist_ok=True)
            if entry.isdir():
                path.mkdir(exist_ok=True)
            elif entry.isfile():
                with source.extractfile(entry) as data, path.open('xb') as output:
                    shutil.copyfileobj(data, output)
                path.chmod(entry.mode & 0o777)
        for entry in entries:
            if entry.issym():
                path = destination / entry.name
                path.symlink_to(entry.linkname)
        for entry in entries:
            path = destination / entry.name
            if entry.issym() and not path.resolve().is_relative_to(destination / 'Glimmer.app'):
                raise ValueError('unsigned symlink chain escapes bundle')
        for entry in reversed(entries):
            if entry.isdir():
                (destination / entry.name).chmod(entry.mode & 0o777)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('unsigned', 'seal', 'verify', 'unpack'))
    parser.add_argument('root', type=Path)
    parser.add_argument('--kind', choices=('unsigned', 'signed'), default='unsigned')
    parser.add_argument('--manifest')
    parser.add_argument('--attempt')
    parser.add_argument('--app', type=Path)
    parser.add_argument('--destination', type=Path)
    args = parser.parse_args()
    try:
        if args.operation == 'unsigned':
            args.root.mkdir(parents=True)
            with tarfile.open(args.root / 'Glimmer.app.tar.gz', 'w:gz', dereference=False) as archive:
                archive.add(args.app, arcname='Glimmer.app')
            if parse_tag(os.environ['RC_TAG'])[2]:
                release_symbols.pack(args.app, args.root, identity())
            seal(args.root, 'unsigned')
        elif args.operation == 'seal':
            seal(args.root, args.kind)
        else:
            manifest = verify(args.root, args.kind, args.manifest or '', args.attempt)
            if args.operation == 'unpack':
                expected = {'Glimmer.app.tar.gz'}
                if parse_tag(os.environ['RC_TAG'])[2]:
                    expected |= {release_symbols.ARCHIVE, release_symbols.MANIFEST}
                    release_symbols.validate(args.root, release_symbols.ARCHIVE, identity(args.attempt))
                if set(manifest['hashes']) != expected or args.kind != 'unsigned':
                    raise ValueError('unexpected unsigned payload')
                unpack(args.root / 'Glimmer.app.tar.gz', args.destination)
    except (ValueError, OSError, KeyError, TypeError, tarfile.TarError) as error:
        parser.exit(1, f'ERR: {error}\n')


if __name__ == '__main__':
    main()
