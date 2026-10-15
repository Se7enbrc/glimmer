#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Prepare and publish immutable candidate assets across disposable runners."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from release_artifact import digest, identity, seal, verify
from release_validation import validate_bundle, validate_distribution

REPO = 'Se7enbrc/glimmer'


def command(args, message, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, timeout=120, **kwargs)
    if result.returncode:
        raise ValueError(message)
    return result.stdout


def source_file(name):
    return command(['git', 'show', f'{os.environ["EXPECTED_SHA"]}:{name}'], 'cannot read reviewed source')


def version():
    values = dict(re.findall(r'^(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = (\S+)$',
                             source_file('Glimmer/Version.xcconfig'), re.M))
    short, build = values['MARKETING_VERSION'], values['CURRENT_PROJECT_VERSION']
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', short) or not re.fullmatch('[1-9][0-9]*', build):
        raise ValueError('invalid release version')
    if os.environ['RC_TAG'].rsplit('-rc.', 1)[0] != short:
        raise ValueError('release tag differs from source version')
    return short, build


def prepare(root, app):
    short, build = version()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    validate_bundle(info, short, build)
    source_info = plistlib.loads(source_file('Glimmer/Info.plist').encode())
    if info['SUPublicEDKey'] != source_info['SUPublicEDKey']:
        raise ValueError('bundle update key differs from reviewed source')
    key = os.environ.get('SPARKLE_ED_PRIVATE_KEY', '')
    if not key or '\n' in key or '\r' in key:
        raise ValueError('missing or multiline Sparkle key')
    tools = command(['scripts/sparkle-tools.sh'], 'cannot prepare pinned Sparkle tools').strip()
    zip_path = root / f'Glimmer-{short}.zip'
    signature = command([f'{tools}/sign_update', '--ed-key-file', '-', str(zip_path)],
                        'update signing failed; nothing published', input=key + '\n')
    match = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)" length="([0-9]+)"', signature)
    if not match or int(match[2]) != zip_path.stat().st_size:
        raise ValueError('update signer returned invalid metadata')
    (root / 'CHANGELOG.md').write_text(source_file('CHANGELOG.md'))
    notes = command([sys.executable, 'scripts/changelog.py', '--version', short,
                     '--changelog', str(root / 'CHANGELOG.md')], 'release notes missing')
    (root / 'notes.md').write_text(notes + f'\nSource: this repo at tag {os.environ["RC_TAG"]} (GPLv3).\n')
    receipt = {'short': short, 'build': build, 'signature': match[1], 'length': match[2],
               'public_key': source_info['SUPublicEDKey']}
    (root / 'release.json').write_text(json.dumps(receipt, sort_keys=True) + '\n')


def persist(root):
    short, _ = version()
    attestation = os.environ.get('RELEASE_ATTESTATION_ID', '')
    if not re.fullmatch('[0-9]+', attestation):
        raise ValueError('release attestation missing')
    bundle = Path(os.environ['RELEASE_PROVENANCE_BUNDLE'])
    if not bundle.is_file() or not bundle.stat().st_size:
        raise ValueError('release provenance missing')
    shutil.copyfile(bundle, root / f'Glimmer-{short}.intoto.jsonl')
    shutil.copyfile(Path(os.environ['RUNNER_TEMP']) / 'glimmer-prerequisites.json', root / 'prerequisites.json')
    seal(root, 'signed')


def load(root):
    proof = verify(root, 'signed', os.environ['SIGNED_MANIFEST'], os.environ['SIGNED_ATTEMPT'])
    short, build = version()
    expected = {f'Glimmer-{short}.{suffix}' for suffix in ('dmg', 'zip', 'intoto.jsonl')}
    if set(proof['hashes']) != expected | {'release.json', 'notes.md', 'CHANGELOG.md', 'prerequisites.json'}:
        raise ValueError('signed artifact file set mismatch')
    receipt = json.loads((root / 'release.json').read_text())
    if receipt.get('short') != short or receipt.get('build') != build:
        raise ValueError('signed artifact version mismatch')
    if receipt.get('length') != str((root / f'Glimmer-{short}.zip').stat().st_size):
        raise ValueError('signed artifact length mismatch')
    return receipt, proof


def validate(root):
    receipt, _ = load(root)
    zip_path = root / f'Glimmer-{receipt["short"]}.zip'
    command(['scripts/verify-update-signature.swift', receipt['public_key'], receipt['signature'], str(zip_path)],
            'update signature rejected')
    with tempfile.TemporaryDirectory() as directory:
        command(['ditto', '-x', '-k', str(zip_path), directory], 'cannot extract signed app')
        app = Path(directory) / 'Glimmer.app'
        validate_bundle(plistlib.loads((app / 'Contents/Info.plist').read_bytes()), receipt['short'], receipt['build'])
        validate_distribution(str(app))


def release_data(tag):
    # Listing distinguishes an absent release from an authentication or service failure, including drafts.
    pages = json.loads(command(['gh', 'api', '--paginate', '--slurp', f'repos/{REPO}/releases?per_page=100'],
                               'cannot list releases; nothing changed'))
    matches = [item for page in pages for item in page if item['tag_name'] == tag]
    if len(matches) > 1:
        raise ValueError('duplicate candidate release')
    return matches[0] if matches else None


def upload_missing(data, paths, tag):
    missing = []
    for path in paths:
        matches = [asset for asset in data.get('assets', []) if asset['name'] == path.name]
        if len(matches) > 1:
            raise ValueError('duplicate release asset')
        if matches:
            if matches[0].get('digest') != f'sha256:{digest(path)}' or matches[0].get('state') != 'uploaded':
                raise ValueError('existing asset differs; never replace published bytes')
        else:
            missing.append(path)
    for path in missing:
        command(['gh', 'release', 'upload', tag, str(path), '-R', REPO], 'asset upload failed; retry publication')


def await_release(tag):
    # GitHub's list endpoint can lag a successful draft creation or publication.
    for delay in (0, 0.25, 0.5, 1):
        if delay:
            time.sleep(delay)
        data = release_data(tag)
        if data is not None:
            return data
    raise ValueError('candidate not visible in release listing yet; retry publication')


def publish(root):
    receipt, proof = load(root)
    tag, sha = os.environ['RC_TAG'], os.environ['EXPECTED_SHA']
    actual = command(['gh', 'api', f'repos/{REPO}/commits/{tag}', '--jq', '.sha'], 'cannot resolve tag').strip()
    if actual != sha:
        raise ValueError('candidate tag moved; nothing published')
    data = release_data(tag)
    title = f'Glimmer {receipt["short"]} (RC {tag.rsplit(".", 1)[1]})'
    if data is None:
        command(['gh', 'release', 'create', tag, '-R', REPO, '--draft', '--prerelease', '--latest=false',
                 '--verify-tag', '--title', title, '--notes-file', str(root / 'notes.md')], 'cannot create candidate')
        data = await_release(tag)
    if not data.get('prerelease'):
        raise ValueError('candidate is already stable; use promotion recovery')
    paths = [root / name for name in proof['hashes'] if name.endswith(('.dmg', '.zip', '.intoto.jsonl'))]
    upload_missing(data, paths, tag)
    if data.get('draft'):
        command(['gh', 'release', 'edit', tag, '-R', REPO, '--draft=false', '--prerelease', '--latest=false'],
                'cannot publish candidate; retry publication')
    if await_release(tag).get('draft'):
        raise ValueError('candidate is still a draft')
    # Record visibility before the feed mutation so a late failure has an honest recovery message.
    Path(os.environ['RUNNER_TEMP'], 'glimmer-publication-state').write_text('candidate published; feed pending')
    publish_feed(root, receipt, tag)
    Path(os.environ['RUNNER_TEMP'], 'glimmer-publication-state').write_text('candidate and feed published')


def publish_feed(root, receipt, tag):
    command(['git', 'fetch', '--quiet', 'origin', '+refs/heads/appcast:refs/remotes/origin/appcast'],
            'candidate published; cannot fetch feed')
    head = command(['git', 'rev-parse', 'origin/appcast'], 'cannot resolve feed').strip()
    original = command(['git', 'show', f'{head}:appcast.xml'], 'cannot read feed')
    with tempfile.TemporaryDirectory() as directory:
        feed = Path(directory) / 'appcast.xml'
        feed.write_text(original)
        command([sys.executable, 'scripts/update-appcast.py', str(feed), '--short-version', receipt['short'],
                 '--version', receipt['build'], '--url',
                 f'https://github.com/{REPO}/releases/download/{tag}/Glimmer-{receipt["short"]}.zip',
                 '--ed-signature', receipt['signature'], '--length', receipt['length'], '--min-system', '26.0',
                 '--channel', 'rc', '--title', f'{receipt["short"]} (RC {tag.rsplit(".", 1)[1]})',
                 '--changelog', str(root / 'CHANGELOG.md')], 'candidate published; feed update rejected')
        if feed.read_text() != original:
            command([sys.executable, 'scripts/github_signed_commit.py', REPO, 'appcast', head,
                     'appcast.xml', str(feed), f'appcast: Glimmer {tag}'],
                    'candidate published; retry feed publication')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('prepare', 'persist', 'validate', 'check', 'publish', 'unpublished'))
    parser.add_argument('root', type=Path)
    parser.add_argument('--app', type=Path)
    args = parser.parse_args()
    try:
        identity()
        if args.phase == 'unpublished':
            if release_data(os.environ['RC_TAG']) is not None:
                raise ValueError('candidate already exists; retry publication with persisted bytes, never rebuild')
        elif args.phase == 'prepare':
            prepare(args.root, args.app)
        else:
            {'persist': persist, 'validate': validate, 'check': load, 'publish': publish}[args.phase](args.root)
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f'ERR: {error}\n')


if __name__ == '__main__':
    main()
