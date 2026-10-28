# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Check post-boot speech settings without enumerating or starting simulators."""

import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("silence", Path(__file__).resolve().parents[1] / "check-journey-silence.py")
SILENCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SILENCE)
KEYS = ("VoiceOverTouchEnabled", "SpeakScreenEnabled")


class JourneySilenceTests(unittest.TestCase):
    def test_booted_check_reads_both_live_keys_without_global_inventory(self):
        with patch.object(SILENCE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "0\n", "")) as run:
            SILENCE.check_simulator("owned-device", booted=True)
        self.assertEqual([call.args[0] for call in run.call_args_list], [
            ["xcrun", "simctl", "spawn", "owned-device", "defaults", "read", "com.apple.Accessibility", key] for key in KEYS])
        self.assertTrue(all(call.kwargs["timeout"] == 30 for call in run.call_args_list))

    def test_either_enabled_speech_setting_refuses_testing(self):
        for enabled in KEYS:
            def execute(command, **options):
                return subprocess.CompletedProcess(command, 0, "1" if command[-1] == enabled else "0", "")
            with self.subTest(key=enabled), patch.object(SILENCE.subprocess, "run", side_effect=execute):
                with self.assertRaisesRegex(RuntimeError, enabled + " is enabled"):
                    SILENCE.check_simulator("owned-device", booted=True)

    def test_live_command_failures_and_unknown_values_fail_closed_for_either_key(self):
        for failed_key in KEYS:
            for failure in (subprocess.CompletedProcess([], 1, "", "device does not exist"),
                            subprocess.CompletedProcess([], 0, "unexpected", ""),
                            subprocess.TimeoutExpired("spawn", 30), OSError("could not launch defaults")):
                def execute(command, **options):
                    if command[-1] != failed_key:
                        return subprocess.CompletedProcess(command, 0, "0", "")
                    if isinstance(failure, Exception):
                        raise failure
                    return failure
                with self.subTest(key=failed_key, failure=failure), patch.object(SILENCE.subprocess, "run", side_effect=execute):
                    with self.assertRaises((RuntimeError, OSError, subprocess.TimeoutExpired)):
                        SILENCE.check_simulator("owned-device", booted=True)

    def test_only_recognized_missing_key_errors_mean_the_setting_is_unset(self):
        for template in ("Error: Could not find key '{key}' in domain 'com.apple.Accessibility'.",
                         "The domain/default pair of (com.apple.Accessibility, {key}) does not exist"):
            def execute(command, **options):
                return subprocess.CompletedProcess(command, 1, "", template.format(key=command[-1]))
            with self.subTest(template=template), patch.object(SILENCE.subprocess, "run", side_effect=execute):
                SILENCE.check_simulator("owned-device", booted=True)


if __name__ == "__main__":
    unittest.main()
