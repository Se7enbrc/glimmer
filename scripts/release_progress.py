# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Keep release waits visible even while a child process or API call blocks."""

from contextlib import contextmanager
from datetime import datetime, timezone
import sys
from threading import Event, Thread
from time import monotonic

HEARTBEAT_SECONDS = 60


def report(message):
    stamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    print(f'[{stamp}] {message}', file=sys.stderr, flush=True)


@contextmanager
def progress(label, timeout):
    started = monotonic()
    stopped = Event()
    detail = label

    def update(message):
        nonlocal detail
        detail = f'{label}: {message}'
        report(detail)

    def heartbeat():
        while not stopped.wait(HEARTBEAT_SECONDS):
            report(f'Waiting: {detail} ({int(monotonic() - started)}s elapsed; timeout {timeout:g}s)')

    report(f'Starting: {label} (timeout {timeout:g}s)')
    worker = Thread(target=heartbeat, daemon=True)
    worker.start()
    failed = True
    try:
        yield update
        failed = False
    finally:
        stopped.set()
        worker.join()
        elapsed = int(monotonic() - started)
        if failed:
            report(f'Ended: {label} (failed or interrupted after {elapsed}s)')
        else:
            report(f'Completed: {label} ({elapsed}s elapsed)')
