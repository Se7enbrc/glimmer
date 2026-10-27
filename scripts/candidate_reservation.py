# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Hold one candidate and serialize delivery admission with safe retirement."""

import argparse
import importlib
import json
import os
import re
import subprocess
import time

from release_candidate_kind import parse_tag
from release_progress import progress, report

BRANCH = 'refs/heads/release-candidate'
RESERVATION = 'refs/heads/candidate-reservation'
DELIVERIES = ('release.yml', 'ios-testflight-build.yml', 'ios-testflight.yml')
ADMISSIONS = {'.github/workflows/release.yml': {BRANCH, 'refs/heads/main'},
              '.github/workflows/ios-testflight.yml': {'refs/heads/main'}}


class AdmissionPending(ValueError):
    """Only the trusted controller may admit this delivery attempt."""


def claim_key(delivery):
    if (not isinstance(delivery, dict) or set(delivery) != {'run', 'attempt', 'sha', 'ref', 'workflow'}
            or any(type(delivery.get(key)) is not int or delivery[key] < 1 for key in ('run', 'attempt'))
            or not re.fullmatch(r'[0-9a-f]{40}', delivery.get('sha', ''))
            or delivery.get('ref') not in ADMISSIONS.get(delivery.get('workflow'), set())):
        raise ValueError('invalid delivery identity')
    return f"{delivery['run']}:{delivery['attempt']}"


def current_delivery():
    if (os.environ.get('GITHUB_REPOSITORY') != 'Se7enbrc/glimmer'
            or os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'):
        raise ValueError('delivery admission requires an upstream manual workflow')
    ref = os.environ.get('GITHUB_REF', '')
    workflow_ref = os.environ.get('GITHUB_WORKFLOW_REF', '')
    prefix, suffix = 'Se7enbrc/glimmer/', '@' + ref
    if not workflow_ref.startswith(prefix) or not workflow_ref.endswith(suffix):
        raise ValueError('delivery workflow ref differs from its execution')
    delivery = {'run': int(os.environ.get('GITHUB_RUN_ID', '')),
                'attempt': int(os.environ.get('GITHUB_RUN_ATTEMPT', '')),
                'sha': os.environ.get('GITHUB_SHA', ''), 'ref': ref,
                'workflow': workflow_ref[len(prefix):-len(suffix)]}
    claim_key(delivery)
    return delivery


def record(message):
    data = json.loads(message)
    if (not isinstance(data, dict) or data.get('schema') not in (1, 2)
            or not re.fullmatch(r'[0-9a-f]{40}', data.get('sha', ''))
            or data.get('state') not in ('reserved', 'closing', 'released', 'abandoned')):
        raise ValueError('invalid candidate reservation')
    if data['schema'] == 1 and ('claims' in data or data['state'] == 'closing'):
        raise ValueError('legacy reservations cannot carry delivery claims or fences')
    claims = data.get('claims', {} if data['schema'] == 1 else None)
    if (not isinstance(claims, dict) or any(key != claim_key(value) for key, value in claims.items())
            or any(value['ref'] == BRANCH and value['sha'] != data['sha'] for value in claims.values())
            or (data['state'] in ('released', 'abandoned') and claims)):
        raise ValueError('invalid candidate delivery claims')
    data['claims'] = claims
    return data


def require(sha, object_api, delivery=False):
    ref = object_api('git/ref/heads/candidate-reservation')['object']
    if ref.get('type') != 'commit':
        raise ValueError('candidate reservation is not a commit')
    data = record(object_api(f"git/commits/{ref['sha']}")['message'])
    allowed = ('reserved', 'closing') if delivery else ('reserved',)
    if data['sha'] != sha or data['state'] not in allowed:
        raise ValueError('candidate is not reserved for Mac and iOS delivery')
    if delivery:
        identity = current_delivery()
        claim = data['claims'].get(claim_key(identity))
        if claim is None and data['state'] == 'reserved':
            raise AdmissionPending('waiting for trusted delivery admission')
        if claim != identity:
            raise ValueError('this delivery attempt has no matching admission')
    return ref['sha']


def git(*args, input=None):
    with progress(f"reservation git {args[0]}: {BRANCH}, {RESERVATION}", 300):
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
        with progress(f'delivery lookup: https://github.com/Se7enbrc/glimmer/actions/workflows/{workflow}', 60):
            pages = checks.api(f'actions/workflows/{workflow}/runs?per_page=100')
        if not pages or any(not isinstance(page, dict) or not isinstance(page.get('workflow_runs'), list)
                            for page in pages):
            raise ValueError('delivery run lookup returned invalid data')
        if any(page.get('total_count', 0) >= 1000 for page in pages):
            raise ValueError('delivery history may be truncated; inspect and partition before releasing')
        runs = [run for page in pages for run in page.get('workflow_runs', [])]
        for run in runs:
            if run.get('status') != 'completed':
                raise ValueError(f"delivery pending: {workflow} run {run.get('id', 'unknown')} "
                                 f"({run.get('status', 'unknown')}, SHA {run.get('head_sha', 'unknown')}); "
                                 'finish or cancel it first')


def commit_record(sha, state, claims, parent, superseded_by=None):
    tree = git('mktree', input='')
    data = {'schema': 2, 'sha': sha, 'state': state, 'claims': claims if claims is not None else {}}
    if superseded_by:
        data['superseded_by'] = superseded_by
    message = json.dumps(data, sort_keys=True)
    record(message)
    return git('commit-tree', tree, *(['-p', parent] if parent else []), '-m', message)


def write(refs, sha, state, claims=None, superseded=None):
    parent = refs.get(RESERVATION, '')
    if superseded:
        # Publish retirement and replacement together; admission races lose the same lease.
        parent = commit_record(superseded, 'abandoned', {}, parent, superseded_by=sha)
    commit = commit_record(sha, state, claims, parent)
    command = ['push', '--atomic', f"--force-with-lease={RESERVATION}:{refs.get(RESERVATION, '')}"]
    updates = [f'{commit}:{RESERVATION}']
    if state == 'reserved' and claims is None:
        command.append(f"--force-with-lease={BRANCH}:{refs.get(BRANCH, '')}")
        updates.append(f'{sha}:{BRANCH}')
    git(*command, 'origin', *updates)


def candidate_version(sha):
    config = git('show', f'{sha}:Glimmer/Version.xcconfig')
    values = dict(re.findall(r'^(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)\s*$', config, re.M))
    version, build = values.get('MARKETING_VERSION', ''), values.get('CURRENT_PROJECT_VERSION', '')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError(f'candidate {sha} has invalid version or build metadata')
    return version, int(build)


def unpublished(version, checks):
    if git('ls-remote', 'origin', f'refs/tags/{version}'):
        raise ValueError(f'{version} has a final tag; cannot automatically abandon a promoted candidate')
    with progress('GA publication lookup: https://github.com/Se7enbrc/glimmer/releases', 60):
        pages = checks.api('releases?per_page=100')
    if not pages or any(not isinstance(page, list) for page in pages):
        raise ValueError('release lookup returned invalid data; cannot automatically retire candidate')
    for release in (item for page in pages for item in page):
        if not isinstance(release, dict) or not isinstance(release.get('tag_name'), str):
            raise ValueError('release lookup returned invalid data')
        tag = release['tag_name']
        try:
            short = parse_tag(tag)[0]
        except ValueError:
            short = tag
        if short == version and release.get('prerelease') is not True:
            raise ValueError(f'{tag} is a GA release; cannot automatically abandon a published candidate')


def superseded_candidate(refs, data, sha, checks):
    if refs.get(BRANCH) != data['sha']:
        raise ValueError('reserved candidate branch moved; review recovery before continuing')
    if data['claims']:
        names = ', '.join(f"{claim['workflow']} run {claim['run']} attempt {claim['attempt']}"
                          for claim in data['claims'].values())
        raise ValueError(f'candidate has admitted deliveries: {names}; finish and reconcile them first')
    git('fetch', '--quiet', 'origin', data['sha'])
    old_version, old_build = candidate_version(data['sha'])
    version, build = candidate_version(sha)
    if version != old_version or build <= old_build:
        raise ValueError(f"candidate {data['sha']} is reserved ({old_version} build {old_build}); "
                         'automatic retirement requires the same marketing version and a higher build')
    unpublished(old_version, checks)
    return data['sha']


def reserve(sha, dry_run, checks):
    refs, data = snapshot()
    report(f"Reservation for {sha}: " + (f"{data['sha']} is {data['state']}" if data else 'no held candidate'))
    superseded = None
    if data and data['state'] == 'closing':
        raise ValueError('candidate is closing; drain admitted deliveries and finish retirement first')
    if data and data['state'] == 'reserved':
        if data['sha'] == sha:
            if refs.get(BRANCH) != sha:
                raise ValueError('reserved candidate branch moved; review recovery before continuing')
            return False
        superseded = superseded_candidate(refs, data, sha, checks)
    elif data and data['sha'] == sha:
        raise ValueError('this candidate was released or abandoned; use a new source commit')
    quiescent(checks)
    if dry_run:
        if superseded:
            print(f'Would abandon candidate {superseded}, superseded by {sha}, in the atomic reservation')
        print(f'Would atomically reserve {sha} for Mac and iOS and move release-candidate')
    elif superseded:
        write(refs, sha, 'reserved', superseded=superseded)
        print(f'Abandoned candidate {superseded}, superseded by {sha}, in the atomic reservation')
    else:
        write(refs, sha, 'reserved')
    return True


def admit(sha, delivery):
    key = claim_key(delivery)
    for _ in range(3):
        refs, data = snapshot()
        if (not data or data['sha'] != sha or data['state'] not in ('reserved', 'closing')
                or refs.get(BRANCH) != sha):
            raise ValueError('candidate is not held for delivery admission')
        claims = dict(data['claims'])
        if key in claims:
            if claims[key] != delivery:
                raise ValueError('delivery claim identity changed')
            return
        if data['state'] != 'reserved':
            raise ValueError('candidate is closing; new delivery admission is denied')
        if delivery['ref'] == BRANCH and delivery['sha'] != sha:
            raise ValueError('candidate delivery source differs from the held ref')
        claims[key] = delivery
        try:
            write(refs, sha, 'reserved', claims)
            return
        except ValueError:
            continue
    raise ValueError('delivery admission lost its reservation lease; retry the controller')


def depart(sha, delivery):
    key = claim_key(delivery)
    for _ in range(3):
        refs, data = snapshot()
        if not data or data['sha'] != sha or key not in data['claims']:
            return
        if data['claims'][key] != delivery:
            raise ValueError('completed delivery differs from its admission')
        claims = dict(data['claims'])
        del claims[key]
        try:
            write(refs, sha, data['state'], claims)
            return
        except ValueError:
            continue
    raise ValueError('delivery completion lost its reservation lease; retry the controller')


def finish(sha, state, checks):
    refs, data = snapshot()
    if (not data or data['sha'] != sha or data['state'] not in ('reserved', 'closing')
            or refs.get(BRANCH) != sha or state not in ('released', 'abandoned')):
        raise ValueError('only the held candidate can be released or abandoned')
    if data['state'] == 'reserved':
        write(refs, sha, 'closing', data['claims'])
        refs, data = snapshot()
    if data['sha'] != sha or data['state'] != 'closing' or refs.get(BRANCH) != sha:
        raise ValueError('candidate changed during retirement')
    if data['claims']:
        raise ValueError('admitted deliveries must finish before retirement; candidate remains closing')
    quiescent(checks)
    write(refs, sha, state, {})


def wait(sha, object_api, budget):
    deadline = time.monotonic() + 20 * 60
    run = os.environ.get('GITHUB_RUN_ID', '')
    links = 'https://github.com/Se7enbrc/glimmer/actions/workflows/candidate-delivery.yml'
    if run:
        links += f'; delivery https://github.com/Se7enbrc/glimmer/actions/runs/{run}'
    with progress(f'delivery admission for {sha}: {links}', 20 * 60), budget(deadline):
        while time.monotonic() < deadline:
            try:
                require(sha, object_api, delivery=True)
                if time.monotonic() >= deadline:
                    raise ValueError('delivery admission timed out; inspect the trusted controller')
                return
            except AdmissionPending:
                time.sleep(min(10, max(0, deadline - time.monotonic())))
        raise ValueError('delivery admission timed out; inspect the trusted controller')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('release', 'abandon', 'wait'))
    parser.add_argument('sha', help='full held candidate SHA')
    args = parser.parse_args()
    try:
        if not re.fullmatch(r'[0-9a-f]{40}', args.sha):
            raise ValueError('candidate SHA must be full lowercase hex')
        checks = importlib.import_module('release-checks')
        if args.operation == 'wait':
            wait(args.sha, checks.object_api, checks.read_budget)
        else:
            finish(args.sha, 'released' if args.operation == 'release' else 'abandoned', checks)
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'ERR: {error}\n')
    print(f'Candidate {args.sha}: {args.operation} complete.', flush=True)


if __name__ == '__main__':
    main()
