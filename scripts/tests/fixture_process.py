# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Subprocess bounds for integration fixtures, independent of production deadlines."""

import math
import os
import signal
import subprocess

# This catches hangs, not slow machines; loaded runners can raise it in seconds.
FIXTURE_TIMEOUT = float(os.environ.get("GLIMMER_TEST_TIMEOUT", "300"))
if not math.isfinite(FIXTURE_TIMEOUT) or FIXTURE_TIMEOUT <= 0:
    raise ValueError("GLIMMER_TEST_TIMEOUT must be a positive finite number of seconds")


def run_fixture(args, *, timeout=FIXTURE_TIMEOUT, check=False, **kwargs):
    with subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          start_new_session=True, **kwargs) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except BaseException as error:
            # A shell's children can still write into fixtures after the shell dies.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate()
            if isinstance(error, subprocess.TimeoutExpired):
                error.output, error.stderr = stdout, stderr
            raise
        result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
        if check:
            result.check_returncode()
        return result
