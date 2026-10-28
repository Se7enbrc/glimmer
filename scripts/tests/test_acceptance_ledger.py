# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Acceptance resumes partial work and reports its actual source instead of borrowing a green SHA."""

import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

from fixture_git import FixtureTestCase
from test_ci_local import load, RUNNER

LEDGER = load("acceptance_ledger")
SHA = "a" * 40


class AcceptanceLedgerTests(FixtureTestCase):
    def fixture(self, root):
        folder = root / "GlimmerUITests"
        folder.mkdir()
        source = folder / "MacControllerJourneyUITests.swift"
        source.write_text("""class MacControllerJourneyUITests {
    func testFirst() throws {
        try helper()
    }
    func testSecond() throws {
        try helper()
    }
    func helper() throws { print("shared") }
}
""")
        return source

    def test_partial_batch_resume_only_runs_failed_or_missing_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            path = root / "ledger.json"
            cases = LEDGER.definitions(root)
            ledger = LEDGER.load(path, "2026.10.8")
            LEDGER.pending(ledger, cases)
            batch = [case for case in cases if case["theme"] == "light"]
            results = {batch[0]["test"]: "passed", batch[1]["test"]: "failed"}
            LEDGER.record(ledger, batch, results, SHA, "hosted-result", "123")
            LEDGER.save(ledger, path)
            resumed = LEDGER.load(path, "2026.10.8")
            pending = LEDGER.pending(resumed, cases)
            self.assertEqual(len(pending), 3)
            self.assertNotIn(batch[0]["key"], [case["key"] for case in pending])
            self.assertEqual(resumed["cases"][batch[0]["key"]]["history"][0]["sha"], SHA)

    def test_forced_rerun_stays_pending_if_cancelled_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            path = root / "ledger.json"
            cases = LEDGER.definitions(root)
            ledger = LEDGER.load(path, "2026.10.8")
            LEDGER.pending(ledger, cases)
            LEDGER.record(ledger, cases, {case["test"]: "passed" for case in cases}, SHA, "result", "123")
            selected = LEDGER.pending(ledger, cases, "mac/light/*testFirst")
            self.assertEqual(len(selected), 1)
            LEDGER.save(ledger, path)
            resumed = LEDGER.load(path, "2026.10.8")
            self.assertEqual(LEDGER.pending(resumed, cases), selected)
            self.assertEqual([item["status"] for item in resumed["cases"][selected[0]["key"]]["history"]],
                             ["passed", "pending"])

    def test_changing_one_method_preserves_other_passes_but_helpers_invalidate_users(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.fixture(root)
            path = root / "ledger.json"
            cases = LEDGER.definitions(root)
            ledger = LEDGER.load(path, "2026.10.8")
            LEDGER.pending(ledger, cases)
            LEDGER.record(ledger, cases, {case["test"]: "passed" for case in cases}, SHA, "result", "123")
            source.write_text(source.read_text().replace("try helper()", "try helper(); print(1)", 1))
            changed = LEDGER.pending(ledger, LEDGER.definitions(root))
            self.assertEqual(len(changed), 2)
            self.assertTrue(all(case["test"].endswith("testFirst") for case in changed))
            source.write_text(source.read_text().replace('print("shared")', 'print("changed helper")'))
            self.assertEqual(len(LEDGER.pending(ledger, LEDGER.definitions(root))), 4)

    def test_extensions_and_ipad_only_cases_have_exact_device_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "iOS/GlimmerUITests"
            folder.mkdir(parents=True)
            template = "extension %s {\n    func testExample() throws {\n        print(1)\n    }\n}\n"
            (folder / "ControllerMouseJourneyUITests.swift").write_text(template % "ControllerJourneyUITests")
            (folder / "IPadTouchJourneyUITests.swift").write_text(template % "IPadTouchJourneyUITests")
            cases = LEDGER.definitions(root)
            self.assertEqual(len(cases), 6)
            self.assertTrue(all(case["device"] == "ipad" for case in cases if case["test"].startswith("IPad")))

    def test_xcresult_partial_and_repeated_cases_do_not_turn_failures_green(self):
        leaf = lambda name, result: {"nodeType": "Test Case", "nodeIdentifier": f"ControllerJourneyUITests/{name}()",
                                    "result": result}
        document = {"testNodes": [{"children": [leaf("testPass", "Passed"), leaf("testFail", "Failed"),
                                                leaf("testFail", "Passed"), leaf("testSkip", "Skipped")]}]}
        self.assertEqual(LEDGER.outcomes(document), {"ControllerJourneyUITests/testPass": "passed",
                         "ControllerJourneyUITests/testFail": "failed", "ControllerJourneyUITests/testSkip": "failed"})

    def test_release_mismatch_and_unmatched_rerun_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ledger.json"
            LEDGER.save(LEDGER.load(path, "2026.10.8"), path)
            with self.assertRaises(ValueError):
                LEDGER.load(path, "2026.11.1")
            with self.assertRaises(ValueError):
                LEDGER.pending(LEDGER.load(path, "2026.10.8"), [], "misspelled/*")

    def test_local_import_is_honest_private_and_requires_definition_review_to_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            receipt = root / "private-local-tests.json"
            receipt.write_text(json.dumps({"testNodes": [{"nodeType": "Test Case", "result": "Passed",
                "nodeIdentifier": "MacControllerJourneyUITests/testFirst()"}]}))
            path = root / "ledger.json"
            args = ["acceptance_ledger", "--release", "2026.10.8", "--ledger", str(path), "--source-root", str(root),
                    "--tests-json", str(receipt), "--device", "mac", "--theme", "light", "--source-note", "reviewed working tree"]
            with patch.object(sys, "argv", args), contextlib.redirect_stdout(io.StringIO()):
                LEDGER.main()
            state = LEDGER.load(path, "2026.10.8")
            self.assertEqual(len(LEDGER.pending(state, LEDGER.definitions(root))), 4)
            with patch.object(sys, "argv", [*args, "--reviewed-current-definitions"]), contextlib.redirect_stdout(io.StringIO()):
                LEDGER.main()
            state = LEDGER.load(path, "2026.10.8")
            self.assertEqual(len(LEDGER.pending(state, LEDGER.definitions(root))), 3)
            self.assertNotIn(str(root), path.read_text())
            history = state["cases"]["mac/light/MacControllerJourneyUITests/testFirst"]["history"]
            self.assertIsNone(history[-1]["sha"])
            self.assertEqual(history[-1]["source_note"], "reviewed working tree")

    def test_execution_batches_methods_and_resume_does_not_rebuild_passed_platform_batches(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            args = SimpleNamespace(ledger=root / "acceptance/ledger.json", release="2026.10.8", rerun="", only="")
            calls = []
            first_attempt = True
            def execute(command, log, timeout):
                calls.append((os.environ["JOURNEY_APPEARANCE"], os.environ["JOURNEY_TEST_FLAGS"],
                              os.environ["JOURNEY_SKIP_BUILD"]))
                (Path(os.environ["JOURNEY_RESULTS"]) / "result.xcresult").mkdir()
                return 1 if first_attempt and os.environ["JOURNEY_APPEARANCE"] == "light" else 0
            def output(command, *unused):
                if command[:2] == ["git", "rev-parse"]:
                    return SHA
                if command[:2] == ["git", "status"]:
                    return ""
                if "--show-sdk-version" in command:
                    return "26.5"
                methods = [item.rsplit(":", 1)[1].removeprefix("GlimmerUITests/")
                           for item in os.environ["JOURNEY_TEST_FLAGS"].split()]
                failed = first_attempt and os.environ["JOURNEY_APPEARANCE"] == "light"
                return json.dumps({"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": method + "()",
                    "result": "Failed" if failed and method.endswith("testSecond") else "Passed"} for method in methods]})
            with patch.dict(os.environ), patch.object(RUNNER, "ROOT", root), patch.object(RUNNER, "toolchain"), \
                    patch.object(RUNNER, "output", side_effect=output), patch.object(RUNNER, "run", side_effect=execute), \
                    patch.object(RUNNER, "ios", return_value=0) as render, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(RUNNER.acceptance(args), 1)
                self.assertEqual(len(calls), 2)
                self.assertEqual([call[2] for call in calls], ["0", "1"])
                self.assertTrue(all(len(call[1].split()) == 2 for call in calls))
                first_attempt = False
                calls.clear()
                self.assertEqual(RUNNER.acceptance(args), 0)
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0][0], "light")
                self.assertEqual(calls[0][1], "-only-testing:GlimmerUITests/MacControllerJourneyUITests/testSecond")
                self.assertEqual(calls[0][2], "0")
                render.assert_called_once()

    def test_infrastructure_failure_stops_before_repeating_the_build_for_other_themes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            args = SimpleNamespace(ledger=root / "acceptance/ledger.json", release="2026.10.8", rerun="", only="")
            def batch(device, theme, cases, destination, built):
                if device == "ios":
                    return 0, {"render": "passed"}
                raise ValueError("Compiler failed; no result bundle")
            with patch.object(RUNNER, "ROOT", root), patch.object(RUNNER, "toolchain"), \
                    patch.object(RUNNER, "output", side_effect=[SHA, ""]), \
                    patch.object(RUNNER, "acceptance_batch", side_effect=batch) as execute, \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(RUNNER.acceptance(args), 1)
            self.assertEqual(execute.call_count, 2)
            state = LEDGER.load(args.ledger, "2026.10.8")
            self.assertEqual(state["cases"]["ios/all/render"]["status"], "passed")
            self.assertTrue(all(entry["status"] == "pending" for key, entry in state["cases"].items() if key.startswith("mac/")))

    def test_focused_acceptance_runs_selected_pending_cases_and_preserves_unrelated_work(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            args = SimpleNamespace(ledger=root / "acceptance/ledger.json", release="2026.10.8", rerun="",
                                   only="mac/light/*/testFirst")
            def batch(device, theme, cases, destination, built):
                self.assertEqual((device, theme), ("mac", "light"))
                self.assertEqual([case["test"] for case in cases], ["MacControllerJourneyUITests/testFirst"])
                return 0, {cases[0]["test"]: "passed"}
            with patch.object(RUNNER, "ROOT", root), patch.object(RUNNER, "toolchain"), \
                    patch.object(RUNNER, "output", side_effect=[SHA, ""]), \
                    patch.object(RUNNER, "acceptance_batch", side_effect=batch) as execute, \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(RUNNER.acceptance(args), 0)
                self.assertEqual(RUNNER.acceptance(args), 0)
                execute.assert_called_once()
                args.only = "misspelled/*"
                with self.assertRaisesRegex(ValueError, "only selector matched no cases"):
                    RUNNER.acceptance(args)
                execute.assert_called_once()
            state = LEDGER.load(args.ledger, args.release)
            self.assertEqual(len(state["active"]), 5)
            self.assertEqual(sum(case["status"] == "pending" for case in state["cases"].values()), 4)
            report = (args.ledger.parent / "summary.md").read_text()
            self.assertIn("1 passed, 0 failed, 4 pending", report)
            self.assertIn("Selected scope: 1 of 5 cases", report)
            self.assertIn("Partial acceptance; success applies only to this scope", report)
