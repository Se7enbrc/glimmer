# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Fixture processes must stop writing before temporary directories are removed."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import unittest
from unittest.mock import call, patch

import fixture_process
from fixture_process import run_fixture


class FixtureProcessTests(unittest.TestCase):
    def test_timeout_kills_the_process_group_and_drains_before_returning(self):
        timeout = subprocess.TimeoutExpired(["fixture"], 300)
        events = []

        def communicate(**kwargs):
            events.append("communicate")
            if kwargs:
                raise timeout
            return "partial output", "failure detail"

        with patch.object(fixture_process.subprocess, "Popen") as start, \
                patch.object(fixture_process.os, "killpg", side_effect=lambda *_: events.append("kill")) as kill:
            process = start.return_value.__enter__.return_value
            process.communicate.side_effect = communicate
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                run_fixture(["fixture"])
            start.assert_called_once_with(["fixture"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                          text=True, start_new_session=True)
            kill.assert_called_once_with(process.pid, signal.SIGKILL)
            self.assertEqual(process.communicate.call_args_list,
                             [call(timeout=fixture_process.FIXTURE_TIMEOUT), call()])
        self.assertEqual(events, ["communicate", "kill", "communicate"])
        self.assertEqual((caught.exception.output, caught.exception.stderr), ("partial output", "failure detail"))

    def test_interrupt_also_stops_and_drains_the_group(self):
        with patch.object(fixture_process.subprocess, "Popen") as start, \
                patch.object(fixture_process.os, "killpg") as kill:
            process = start.return_value.__enter__.return_value
            process.communicate.side_effect = [KeyboardInterrupt(), ("", "")]
            with self.assertRaises(KeyboardInterrupt):
                run_fixture(["fixture"])
            kill.assert_called_once_with(process.pid, signal.SIGKILL)
            self.assertEqual(process.communicate.call_count, 2)

    def test_already_exited_group_does_not_mask_the_timeout(self):
        timeout = subprocess.TimeoutExpired(["fixture"], 300)
        with patch.object(fixture_process.subprocess, "Popen") as start, \
                patch.object(fixture_process.os, "killpg", side_effect=ProcessLookupError):
            process = start.return_value.__enter__.return_value
            process.communicate.side_effect = [timeout, ("", "")]
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                run_fixture(["fixture"])
            self.assertIs(caught.exception, timeout)
            self.assertEqual(process.communicate.call_count, 2)

    def test_timeout_stops_a_real_descendant_without_a_sleep(self):
        original = subprocess.Popen.communicate
        groups = []

        def communicate(process, **kwargs):
            if kwargs:
                groups.append(process.pid)
                self.assertEqual(process.stdout.readline(), "ready\n")
                raise subprocess.TimeoutExpired(process.args, kwargs["timeout"])
            result = original(process)
            groups.remove(process.pid)
            return result

        source = ('import os, signal\n'
                  'if os.fork() == 0:\n'
                  '    print("ready", flush=True)\n'
                  '    signal.pause()\n'
                  'else:\n'
                  '    os.wait()\n')
        try:
            with patch.object(subprocess.Popen, "communicate", autospec=True, side_effect=communicate):
                with self.assertRaises(subprocess.TimeoutExpired):
                    run_fixture([sys.executable, "-c", source])
            self.assertEqual(groups, [], "descendant pipes must reach EOF before fixture cleanup")
        finally:
            for group in groups:
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_results_and_checked_failures_keep_their_output(self):
        command = [sys.executable, "-c", 'import sys; print("out"); sys.stderr.write("err"); sys.exit(7)']
        result = run_fixture(command)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (7, "out\n", "err"))
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            run_fixture(command, check=True)
        self.assertEqual((caught.exception.returncode, caught.exception.stdout, caught.exception.stderr),
                         (7, "out\n", "err"))

    def test_timeout_default_and_environment_override(self):
        env = {key: value for key, value in os.environ.items() if key != "GLIMMER_TEST_TIMEOUT"}
        command = [sys.executable, "-c", 'import fixture_process; print(fixture_process.FIXTURE_TIMEOUT)']
        for value, expected in ((None, "300.0"), ("901.25", "901.25")):
            with self.subTest(value=value):
                if value is not None:
                    env["GLIMMER_TEST_TIMEOUT"] = value
                result = run_fixture(command, cwd=Path(__file__).parent, env=env, check=True)
                self.assertEqual(result.stdout.strip(), expected)

    def test_invalid_timeout_cannot_disable_the_hang_guard(self):
        for value in ("0", "-1", "nan", "inf"):
            with self.subTest(value=value):
                result = run_fixture([sys.executable, "-c", "import fixture_process"],
                                     cwd=Path(__file__).parent, env={**os.environ, "GLIMMER_TEST_TIMEOUT": value})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("positive finite number", result.stderr)
