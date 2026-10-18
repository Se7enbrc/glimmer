# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Preserve matching app/engine dSYMs without executing or importing symbol files."""

import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

ARCHIVE = 'Glimmer-symbols.zip'
MANIFEST = 'symbols.json'


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def uuids(path):
    result = subprocess.run(['xcrun', 'dwarfdump', '--uuid', str(path)],
                            capture_output=True, text=True, timeout=30)
    values = sorted(re.findall(r'^UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)', result.stdout, re.M))
    if result.returncode or not values:
        raise ValueError(f'cannot read symbol UUIDs for {path.name}')
    return [[uuid.upper(), architecture] for uuid, architecture in values]


def pack(app, root, identity):
    products = app.parent
    images = {}
    bundles = []
    for name, bundle, executable in (
        ('Glimmer', 'Glimmer.app.dSYM', app / 'Contents/MacOS/Glimmer'),
        ('GlimmerEngine', 'GlimmerEngine.framework.dSYM',
         app / 'Contents/Frameworks/GlimmerEngine.framework/GlimmerEngine'),
    ):
        dsym = products / bundle
        dwarf = dsym / 'Contents/Resources/DWARF' / name
        if not dwarf.is_file():
            raise ValueError(f'diagnostic candidate requires {bundle}')
        binary_ids, symbol_ids = uuids(executable), uuids(dwarf)
        if binary_ids != symbol_ids:
            raise ValueError(f'{bundle} does not match its shipped binary')
        images[name] = {'uuids': binary_ids, 'dsym': bundle}
        bundles.append(dsym)
    with zipfile.ZipFile(root / ARCHIVE, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for bundle in bundles:
            for path in sorted(bundle.rglob('*')):
                if path.is_symlink():
                    raise ValueError('diagnostic symbols must not contain symlinks')
                if path.is_file():
                    archive.write(path, path.relative_to(products))
    record = {'identity': identity, 'images': images, 'sha256': digest(root / ARCHIVE)}
    (root / MANIFEST).write_text(json.dumps(record, sort_keys=True) + '\n')


def validate(root, archive, identity):
    record = json.loads((root / MANIFEST).read_text())
    actual = record.get('identity', {})
    if any(actual.get(key) != value for key, value in identity.items() if key != 'GITHUB_RUN_ATTEMPT'):
        raise ValueError('diagnostic symbols identify a different candidate')
    attempt = actual.get('GITHUB_RUN_ATTEMPT', '')
    if not re.fullmatch('[1-9][0-9]*', attempt) or int(attempt) > int(identity['GITHUB_RUN_ATTEMPT']):
        raise ValueError('invalid diagnostic symbols producing attempt')
    if record.get('sha256') != digest(root / archive):
        raise ValueError('diagnostic symbol archive digest mismatch')
    if set(record.get('images', {})) != {'Glimmer', 'GlimmerEngine'}:
        raise ValueError('diagnostic symbol image map incomplete')
    return record


def carry(source, destination, short, identity):
    record = validate(source, ARCHIVE, identity)
    archive = f'Glimmer-{short}-symbols.zip'
    shutil.copyfile(source / ARCHIVE, destination / archive)
    shutil.copyfile(source / MANIFEST, destination / MANIFEST)
    return {'archive': archive, **record}
