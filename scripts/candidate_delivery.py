#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Reconcile one delivery attempt using only trusted main tooling and API metadata."""

import argparse
import importlib
import os
import re
import subprocess
from urllib.parse import quote

import candidate_reservation as reservation


def identity(run, run_id, attempt, checks):
    workflow = run.get('path')
    delivery = {'run': run.get('id'), 'attempt': run.get('run_attempt'),
                'sha': run.get('head_sha'), 'ref': 'refs/heads/' + run.get('head_branch', ''),
                'workflow': workflow}
    reservation.claim_key(delivery)
    if (delivery['run'] != run_id or delivery['attempt'] != attempt
            or run.get('event') != 'workflow_dispatch'
            or run.get('head_repository', {}).get('full_name') != checks.REPO):
        raise ValueError('delivery attempt is not an upstream manual execution')
    metadata = checks.object_api(f"actions/workflows/{quote(workflow, safe='')}")
    if (metadata.get('path') != workflow or metadata.get('id') != run.get('workflow_id')
            or metadata.get('state') != 'active'):
        raise ValueError('delivery workflow identity changed')
    return delivery


def sync(run_id, attempt, checks):
    run = checks.object_api(f'actions/runs/{run_id}/attempts/{attempt}')
    delivery = identity(run, run_id, attempt, checks)
    _, data = reservation.snapshot()
    if not data:
        raise ValueError('no candidate reservation to reconcile')
    if run.get('status') == 'completed':
        reservation.depart(data['sha'], delivery)
        return
    current = checks.object_api(f'actions/runs/{run_id}')
    if identity(current, run_id, attempt, checks) != delivery or current.get('status') == 'completed':
        raise ValueError('delivery changed before admission; reconcile its current attempt')
    if current.get('status') not in ('queued', 'in_progress', 'waiting', 'pending', 'requested'):
        raise ValueError('delivery status cannot authorize admission')
    reservation.admit(data['sha'], delivery)


def controller_context():
    if (os.environ.get('GITHUB_REPOSITORY') != 'Se7enbrc/glimmer'
            or os.environ.get('GITHUB_REF') != 'refs/heads/main'
            or os.environ.get('GITHUB_EVENT_NAME') not in ('workflow_run', 'workflow_dispatch')
            or os.environ.get('GITHUB_WORKFLOW_REF') !=
            'Se7enbrc/glimmer/.github/workflows/candidate-delivery.yml@refs/heads/main'):
        raise ValueError('delivery controller requires its trusted main workflow')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_id')
    parser.add_argument('attempt')
    args = parser.parse_args()
    try:
        controller_context()
        if any(not re.fullmatch(r'[1-9][0-9]*', value) for value in (args.run_id, args.attempt)):
            raise ValueError('delivery run and attempt must be positive integers')
        sync(int(args.run_id), int(args.attempt), importlib.import_module('release-checks'))
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'ERR: {error}\n')
    print('Delivery admission reconciled against its exact workflow attempt.')


if __name__ == '__main__':
    main()
