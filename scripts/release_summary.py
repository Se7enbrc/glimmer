#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Summarize release progress without copying signing diagnostics or credentials."""

from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
from release_artifact import verify

REPO = 'Se7enbrc/glimmer'
BASE = f'https://github.com/{REPO}'


def api(path):
    result = subprocess.run(['gh', 'api', '--paginate', '--slurp', f'repos/{REPO}/{path}'],
                            capture_output=True, text=True, timeout=60)
    if result.returncode:
        return []
    try:
        return json.loads(result.stdout)
    except ValueError:
        return []


def duration(start, end):
    if not start or not end:
        return 'unfinished'
    return f'{int((datetime.fromisoformat(end) - datetime.fromisoformat(start)).total_seconds())}s'


def report(jobs, release, hashes, build):
    source, tag = os.environ['EXPECTED_SHA'], os.environ['RC_TAG']
    lines = [f'Source: `{source}`. Candidate source: `{os.environ.get("CANDIDATE_SHA") or source}`.',
             f'Trusted main tooling: `{os.environ.get("TRUSTED_TOOLING_SHA", "unavailable")}`.',
             f'RC: `{tag}`. Build: `{build}`. Run: {os.environ["GITHUB_RUN_ID"]}, '
             f'attempt: {os.environ["GITHUB_RUN_ATTEMPT"]}.', '',
             '| Phase | Result | Duration |', '| --- | --- | --- |']
    for job in jobs:
        lines.append(f'| {job["name"]} | {job.get("conclusion") or job.get("status")} | '
                     f'{duration(job.get("started_at"), job.get("completed_at"))} |')
        for step in job.get('steps', []):
            if step.get('started_at') and step.get('conclusion') != 'skipped':
                lines.append(f'| {job["name"]}: {step["name"]} | {step.get("conclusion") or "running"} | '
                             f'{duration(step.get("started_at"), step.get("completed_at"))} |')
    lines += ['', 'Artifact SHA-256:']
    lines += [f'- `{name}`: `{value}`' for name, value in sorted(hashes.items())]
    if not hashes:
        lines.append('- No verified signed handoff available; inspect the signing and persistence phases.')
    if release is None:
        lines += ['', 'Publication state could not be confirmed. Inspect the candidate link before retrying.']
    elif not release:
        lines += ['', 'Nothing published at this candidate tag.']
    elif release.get('draft'):
        lines += ['', 'Candidate draft exists; uploads may be incomplete. Retry publication only.']
    else:
        channel = 'candidate' if release.get('prerelease') else 'stable release'
        lines += ['', f'The {channel} is public. Feed or tap may still need repair.']
    lines += ['', 'Recovery: rerun only failed validation, publication or tap jobs from this run. '
              'They reuse the producing job\'s artifact ID, manifest digest and attempt. '
              'Never rerun build or signing to repair publication. Before compilation has succeeded, '
              'rerun failed jobs; successful verification records from earlier attempts of this run remain valid.',
              'If the source branch moved, tooling left main history, or the 30-day artifact expired, review recovery; '
              'do not replace assets. A promotion can be dispatched from newly reviewed main with the same '
              'candidate SHA only if its shipped inputs still match.',
              f'[Candidate]({BASE}/releases/tag/{tag}) · '
              f'[Pages deployment]({BASE}/actions/workflows/pages.yml) · '
              '[Public appcast](https://se7enbrc.github.io/glimmer/appcast.xml)',
              'Check Pages and the public feed even when a later phase failed.']
    return '\n'.join(lines) + '\n'


def main():
    jobs = [job for page in api(f'actions/runs/{os.environ["GITHUB_RUN_ID"]}/jobs?filter=latest&per_page=100')
            for job in page.get('jobs', [])]
    releases = api('releases?per_page=100')
    release = next((item for page in releases for item in page if item['tag_name'] == os.environ['RC_TAG']), {})
    hashes, build, prerequisites = {}, 'unavailable', None
    root = Path(os.environ['RUNNER_TEMP']) / 'signed'
    try:
        proof = verify(root, 'signed', os.environ['SIGNED_MANIFEST'], os.environ['SIGNED_ATTEMPT'])
        hashes = proof['hashes']
        prerequisites = json.loads((root / 'prerequisites.json').read_text())
        build = json.loads((root / 'release.json').read_text())['build']
    except (ValueError, OSError, KeyError, TypeError):
        result = subprocess.run(['git', 'show', f'{os.environ["EXPECTED_SHA"]}:Glimmer/Version.xcconfig'],
                                capture_output=True, text=True, timeout=30)
        for line in result.stdout.splitlines():
            if line.startswith('CURRENT_PROJECT_VERSION = '):
                build = line.split(' = ', 1)[1]
        if release:
            hashes = {asset['name']: asset['digest'].removeprefix('sha256:')
                      for asset in release.get('assets', []) if asset.get('digest', '').startswith('sha256:')}
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
        output.write(report(jobs, release if releases else None, hashes, build))
        if prerequisites:
            output.write(f'\nPrerequisites accepted before signing `{prerequisites["sha"]}`:\n\n')
            for run in prerequisites['runs']:
                output.write(f'- [{run["workflow"]}, attempt {run["attempt"]}]'
                             f'({BASE}/actions/runs/{run["id"]})\n')
        else:
            output.write('\nExact prerequisite run links are recorded in each checks job summary.\n')


if __name__ == '__main__':
    main()
