# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Hold one candidate for Mac publication and iOS delivery until explicit release."""

import argparse
import importlib
import json
import re
import subprocess

BRANCH = 'refs/heads/release-candidate'
RESERVATION = 'refs/heads/candidate-reservation'
DELIVERIES = ('release.yml', 'ios-testflight-build.yml', 'ios-testflight.yml')


def record(message):
    data = json.loads(message)
    if (not isinstance(data, dict) or data.get('schema') != 1
            or not re.fullmatch(r'[0-9a-f]{40}', data.get('sha', ''))
            or data.get('state') not in ('reserved', 'released', 'abandoned')):
        raise ValueError('invalid candidate reservation')
    return data


def require(sha, object_api):
    ref = object_api('git/ref/heads/candidate-reservation')['object']
    if ref.get('type') != 'commit':
        raise ValueError('candidate reservation is not a commit')
    data = record(object_api(f"git/commits/{ref['sha']}")['message'])
    if data['sha'] != sha or data['state'] != 'reserved':
        raise ValueError('candidate is not reserved for Mac and iOS delivery')
    return ref['sha']


def git(*args, input=None):
    result = subprocess.run(['git', *args], input=input, capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise ValueError('candidate reservation git operation failed; reload state before retrying')
    return result.stdout.strip()


def snapshot():
    refs = {ref: sha for sha, ref in (line.split('\t') for line in
            git('ls-remote', 'origin', BRANCH, RESERVATION).splitlines())}
    old = refs.get(RESERVATION, '')
    if old:
        git('fetch', '--quiet', 'origin', old)
    return refs, record(git('show', '-s', '--format=%B', old)) if old else None


def quiescent(checks):
    # Delivery runs can wait at approval with a main head SHA, so inspect all refs.
    for workflow in DELIVERIES:
        pages = checks.api(f'actions/workflows/{workflow}/runs?per_page=100')
        if not pages or any(not isinstance(page, dict) or not isinstance(page.get('workflow_runs'), list)
                            for page in pages):
            raise ValueError('delivery run lookup returned invalid data')
        if any(page.get('total_count', 0) >= 1000 for page in pages):
            raise ValueError('delivery history may be truncated; inspect and partition before releasing')
        runs = [run for page in pages for run in page.get('workflow_runs', [])]
        if any(run.get('status') != 'completed' for run in runs):
            raise ValueError('Mac publication or iOS delivery is pending; finish or cancel it first')


def write(refs, sha, state):
    tree = git('mktree', input='')
    parent = ['-p', refs[RESERVATION]] if RESERVATION in refs else []
    message = json.dumps({'schema': 1, 'sha': sha, 'state': state}, sort_keys=True)
    commit = git('commit-tree', tree, *parent, '-m', message)
    command = ['push', '--atomic', f"--force-with-lease={RESERVATION}:{refs.get(RESERVATION, '')}"]
    updates = [f'{commit}:{RESERVATION}']
    if state == 'reserved':
        command.append(f"--force-with-lease={BRANCH}:{refs.get(BRANCH, '')}")
        updates.append(f'{sha}:{BRANCH}')
    git(*command, 'origin', *updates)


def reserve(sha, dry_run, checks):
    refs, data = snapshot()
    if data and data['state'] == 'reserved':
        if data['sha'] != sha:
            raise ValueError(f"candidate {data['sha']} is reserved; explicitly release or abandon it first")
        if refs.get(BRANCH) != sha:
            raise ValueError('reserved candidate branch moved; review recovery before continuing')
        return False
    if data and data['sha'] == sha:
        raise ValueError('this candidate was released or abandoned; use a new source commit')
    quiescent(checks)
    if dry_run:
        print(f'Would atomically reserve {sha} for Mac and iOS and move release-candidate')
    else:
        write(refs, sha, 'reserved')
    return True


def finish(sha, state, checks):
    refs, data = snapshot()
    if not data or data['sha'] != sha or data['state'] != 'reserved' or refs.get(BRANCH) != sha:
        raise ValueError('only the held candidate can be released or abandoned')
    quiescent(checks)
    write(refs, sha, state)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('release', 'abandon'))
    parser.add_argument('sha', help='full held SHA; confirms all intended Mac and iOS deliveries are finished')
    args = parser.parse_args()
    try:
        if not re.fullmatch(r'[0-9a-f]{40}', args.sha):
            raise ValueError('candidate SHA must be full lowercase hex')
        checks = importlib.import_module('release-checks')
        finish(args.sha, 'released' if args.operation == 'release' else 'abandoned', checks)
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'ERR: {error}\n')
    print(f'Candidate {args.sha} {args.operation} complete; its delivery gates are now closed.')


if __name__ == '__main__':
    main()
