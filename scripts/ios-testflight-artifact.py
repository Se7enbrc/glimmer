#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Validate and seal the credential-free iOS archive handoff."""

from collections import Counter
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import zipfile

REPOSITORY = 'Se7enbrc/glimmer'
BUNDLE = 'io.ugfugl.Glimmer.iOS'
ARCHIVE = 'Glimmer.xcarchive'
APP = 'Products/Applications/Glimmer.app'
MAX_BYTES = 4 * 1024**3
MAX_FILES = 20000
MAX_REPORTED = 20
MAX_REPORTED_PATH = 160


def validate_inputs(sha, version, build):
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('expected_sha must be a full lowercase commit SHA')
    if not re.fullmatch(r'(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})', version):
        raise ValueError('marketing_version must be three numeric components')
    if not re.fullmatch(r'[1-9][0-9]{0,3}(?:\.(?:0|[1-9][0-9]?)){0,2}', build):
        raise ValueError('build_number must use Apple numeric 4.2.2 component limits')


def identity(env=None, attempt=None):
    env = os.environ if env is None else env
    values = {key: env[key] for key in ('EXPECTED_SHA', 'IOS_VERSION', 'IOS_BUILD_NUMBER', 'GITHUB_REPOSITORY')}
    values['GITHUB_RUN_ID'] = env.get('ARCHIVE_RUN_ID') or env['GITHUB_RUN_ID']
    values['GITHUB_RUN_ATTEMPT'] = attempt or env.get('ARCHIVE_ATTEMPT') or env['GITHUB_RUN_ATTEMPT']
    validate_inputs(values['EXPECTED_SHA'], values['IOS_VERSION'], values['IOS_BUILD_NUMBER'])
    if values['GITHUB_REPOSITORY'] != REPOSITORY:
        raise ValueError('unexpected repository')
    for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT'):
        if not re.fullmatch(r'[1-9][0-9]*', values[key]):
            raise ValueError('invalid producing run or attempt')
    return values


def require_builder(env=None):
    env = os.environ if env is None else env
    ref = env.get('GITHUB_REF', '')
    default = env.get('DEFAULT_BRANCH', '')
    workflow = f'{REPOSITORY}/.github/workflows/ios-testflight-build.yml@{ref}'
    if (env.get('GITHUB_REPOSITORY') != REPOSITORY or env.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'
            or not default or not ref.startswith('refs/heads/') or ref in ('refs/heads/main', f'refs/heads/{default}')
            or env.get('GITHUB_WORKFLOW_REF') != workflow or env.get('GITHUB_SHA') != env.get('EXPECTED_SHA')):
        raise ValueError('archive must run on its exact candidate branch commit, never the default branch')


def require_dispatch(env=None):
    env = os.environ if env is None else env
    expected = f'{REPOSITORY}/.github/workflows/ios-testflight.yml@refs/heads/main'
    if (env.get('GITHUB_REPOSITORY') != REPOSITORY or env.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'
            or env.get('GITHUB_REF') != 'refs/heads/main' or env.get('GITHUB_WORKFLOW_REF') != expected
            or env.get('GITHUB_SHA') != env.get('TRUSTED_TOOLING_SHA')):
        raise ValueError('TestFlight must run from the pinned main workflow')
    for key in ('ACTIONS_STEP_DEBUG', 'ACTIONS_RUNNER_DEBUG', 'RUNNER_DEBUG'):
        if env.get(key, '').lower() in ('true', '1'):
            raise ValueError('debug logging must be disabled for distribution')


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read_plist(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 2 * 1024**2:
        raise ValueError('missing or oversized archive plist')
    with path.open('rb') as stream:
        result = plistlib.load(stream)
    if not isinstance(result, dict):
        raise ValueError('invalid archive plist')
    return result


def regular_files(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('archive root must be a directory, not a link')
    files = []
    size = 0
    for path in root.rglob('*'):
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise ValueError('links and special files are forbidden in iOS artifacts')
        if stat.S_ISREG(mode):
            size += path.stat().st_size
            files.append(path)
        if len(files) > MAX_FILES or size > MAX_BYTES:
            raise ValueError('iOS artifact exceeds its file or size limit')
    return sorted(files)


def validate_app(app, expected):
    info = read_plist(app / 'Info.plist')
    if (info.get('CFBundleIdentifier') != BUNDLE or info.get('CFBundleExecutable') != 'Glimmer'
            or info.get('CFBundleShortVersionString') != expected['IOS_VERSION']
            or info.get('CFBundleVersion') != expected['IOS_BUILD_NUMBER']
            or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']):
        raise ValueError('archive app identity, version or device platform mismatch')
    if not (app / 'Glimmer').is_file():
        raise ValueError('archive app executable missing')
    if any(app.rglob('*.appex')) or (app / 'Watch').exists() or (app / 'PlugIns').exists():
        raise ValueError('nested applications/extensions need an explicit signing design')
    privacy = read_plist(app / 'PrivacyInfo.xcprivacy')
    declarations = privacy.get('NSPrivacyAccessedAPITypes', [])
    required = {'NSPrivacyAccessedAPICategoryUserDefaults', 'NSPrivacyAccessedAPICategorySystemBootTime',
                'NSPrivacyAccessedAPICategoryFileTimestamp'}
    if (privacy.get('NSPrivacyTracking') is not False or privacy.get('NSPrivacyTrackingDomains') != []
            or privacy.get('NSPrivacyCollectedDataTypes') != [] or not isinstance(declarations, list)
            or not all(isinstance(value, dict) and value.get('NSPrivacyAccessedAPITypeReasons')
                       for value in declarations)
            or not required.issubset({value.get('NSPrivacyAccessedAPIType') for value in declarations})):
        raise ValueError('privacy manifest is missing required declarations or changes the tracking policy')
    return info


def uuids(binary):
    result = subprocess.run(['xcrun', 'dwarfdump', '--uuid', str(binary)], check=True,
                            capture_output=True, text=True, timeout=30)
    matches = re.findall(r'^UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)', result.stdout, re.M)
    if not matches:
        raise ValueError('missing Mach-O UUID')
    return sorted((uuid.upper(), arch) for uuid, arch in matches)


def validate_archive(root, expected, check_symbols=True):
    files = regular_files(root)
    if {p.name for p in root.iterdir()} - {'Info.plist', 'Products', 'dSYMs', 'BCSymbolMaps'}:
        raise ValueError('unexpected archive root content')
    applications = root / 'Products/Applications'
    if {p.name for p in applications.iterdir()} != {'Glimmer.app'}:
        raise ValueError('archive must contain exactly the Glimmer app')
    info = read_plist(root / 'Info.plist')
    properties = info.get('ApplicationProperties', {})
    if (properties.get('ApplicationPath') != 'Applications/Glimmer.app'
            or properties.get('CFBundleIdentifier') != BUNDLE
            or properties.get('CFBundleShortVersionString') != expected['IOS_VERSION']
            or properties.get('CFBundleVersion') != expected['IOS_BUILD_NUMBER']):
        raise ValueError('xcarchive application metadata mismatch')
    validate_app(root / APP, expected)
    symbols = root / 'dSYMs/Glimmer.app.dSYM/Contents/Resources/DWARF/Glimmer'
    if not symbols.is_file():
        raise ValueError('matching app dSYM is required')
    if check_symbols and uuids(root / APP / 'Glimmer') != uuids(symbols):
        raise ValueError('app and dSYM UUID mismatch')
    return files


def seal(archive, output, expected):
    files = validate_archive(archive, expected)
    output.mkdir(parents=True, exist_ok=False)
    with zipfile.ZipFile(output / 'archive.zip', 'w', zipfile.ZIP_DEFLATED) as bundle:
        for path in files:
            bundle.write(path, f'{ARCHIVE}/{path.relative_to(archive).as_posix()}')
    manifest = {'schema': 1, 'identity': expected, 'archive_sha256': digest(output / 'archive.zip'),
                'files': {p.relative_to(archive).as_posix(): digest(p) for p in files},
                'app_uuids': uuids(archive / APP / 'Glimmer')}
    (output / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True) + '\n')
    return digest(output / 'manifest.json')


class UnsafeEntries(ValueError):
    """Rejection that carries a bounded, escaped report of every offending entry."""

    def __init__(self, report):
        first = report['violations'][0]
        super().__init__(f"unsafe or duplicate artifact entry ({report['violation_count']} total): "
                         f"{first['reason']} {first['path']}")
        self.report = report


def printable(name):
    return ascii(name)[1:-1][:MAX_REPORTED_PATH]


def entry_problem(entry, name, path, mode, prefixes, names):
    checks = [('noncanonical', str(path) != name or not path.parts), ('absolute', path.is_absolute()),
              ('traversal', '..' in path.parts), ('backslash', '\\' in name),
              ('too-long', len(name) > 1024 or len(path.parts) > 40),
              ('unexpected-root', bool(path.parts) and path.parts[0] not in prefixes),
              ('duplicate', name in names),
              ('link-or-special', stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)),
              ('directory-mode-on-file', stat.S_ISDIR(mode) and not entry.is_dir()),
              ('privileged-bits', bool(mode & 0o7000))]
    return next((reason for reason, failed in checks if failed), None)


def safe_entries(bundle, prefix):
    entries = bundle.infolist()
    prefixes = {prefix} if isinstance(prefix, str) else set(prefix)
    names = set()
    roots = Counter()
    violations = []
    count = 0
    total = 0
    for entry in entries:
        name = entry.filename.rstrip('/') if entry.is_dir() else entry.filename
        path = PurePosixPath(name)
        mode = entry.external_attr >> 16
        roots[printable(path.parts[0]) if path.parts else ''] += 1
        reason = entry_problem(entry, name, path, mode, prefixes, names)
        if reason:
            count += 1
            if len(violations) < MAX_REPORTED:
                kind = {0: 'unset', stat.S_IFREG: 'file', stat.S_IFDIR: 'dir', stat.S_IFLNK: 'link'}
                violations.append({'reason': reason, 'path': printable(entry.filename),
                                   'type': kind.get(stat.S_IFMT(mode), 'special'), 'mode': f'{mode & 0o7777:04o}'})
        names.add(name)
        total += entry.file_size
    if count:
        raise UnsafeEntries({'violation_count': count, 'violations': violations,
                             'roots': dict(roots.most_common(MAX_REPORTED))})
    if not entries or len(entries) > MAX_FILES or total > MAX_BYTES:
        raise ValueError('artifact exceeds its file or size limit')
    return entries


def unpack(zip_path, destination, prefix):
    if destination.exists() or destination.is_symlink():
        raise ValueError('artifact destination already exists')
    with zipfile.ZipFile(zip_path) as bundle:
        entries = safe_entries(bundle, prefix)
        destination.mkdir(parents=True)
        for entry in entries:
            path = destination / entry.filename
            path.parent.mkdir(parents=True, exist_ok=True)
            if entry.is_dir():
                path.mkdir(exist_ok=True)
                continue
            with bundle.open(entry) as source, path.open('xb') as output:
                shutil.copyfileobj(source, output)
            path.chmod((entry.external_attr >> 16) & 0o777 or 0o600)


def import_archive(payload, destination, expected, manifest_hash):
    if not re.fullmatch(r'[0-9a-f]{64}', manifest_hash):
        raise ValueError('missing manifest digest')
    files = regular_files(payload)
    if {p.relative_to(payload).as_posix() for p in files} != {'archive.zip', 'manifest.json'}:
        raise ValueError('unexpected artifact container contents')
    manifest_path = payload / 'manifest.json'
    if manifest_path.stat().st_size > 8 * 1024**2 or digest(manifest_path) != manifest_hash:
        raise ValueError('artifact manifest mismatch')
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get('schema') != 1 or manifest.get('identity') != expected
            or digest(payload / 'archive.zip') != manifest.get('archive_sha256')):
        raise ValueError('artifact identity or archive digest mismatch')
    unpack(payload / 'archive.zip', destination, ARCHIVE)
    archive = destination / ARCHIVE
    contents = {p.relative_to(archive).as_posix(): digest(p) for p in validate_archive(archive, expected)}
    if contents != manifest.get('files') or uuids(archive / APP / 'Glimmer') != [tuple(v) for v in manifest['app_uuids']]:
        raise ValueError('archive file inventory or symbol identity mismatch')
    return archive
