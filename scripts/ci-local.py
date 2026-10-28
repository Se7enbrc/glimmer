#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Run the hosted test shards locally with the same filters, instrumentation and toolchain."""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from threading import Thread
import uuid

ROOT = Path(__file__).resolve().parent.parent


def output(args, timeout=30):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()


def toolchain():
    if not os.environ.get("DEVELOPER_DIR"):
        paths = ("/Applications/Xcode_26.6.app", "/Applications/Xcode-26.6.0.app")
        path = next((Path(path) / "Contents/Developer" for path in paths if Path(path).exists()), None)
        if path:
            os.environ["DEVELOPER_DIR"] = str(path)
    version = output(["xcodebuild", "-version"])
    if version.splitlines()[0] != "Xcode 26.6":
        raise ValueError(f"Expected Xcode 26.6; selected {version}. Set DEVELOPER_DIR explicitly.")
    print(version, flush=True)
    config = ROOT / "build/ci-tests.xcconfig"
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text("ARCHS = arm64\nONLY_ACTIVE_ARCH = YES\n"
                      "COMPILATION_CACHE_ENABLE_CACHING = YES\n"
                      "SWIFT_SUPPRESS_WARNINGS = NO\n"
                      "SWIFT_TREAT_WARNINGS_AS_ERRORS = YES\n"
                      "GCC_TREAT_WARNINGS_AS_ERRORS = YES\n")
    os.environ["XCODE_XCCONFIG_FILE"] = str(config)


def configured_test_sources(project, directory):
    objects = project["objects"]
    targets = [item for item in objects.values() if item["isa"] == "PBXNativeTarget" and item.get("name") == "GlimmerTests"]
    if len(targets) != 1:
        raise ValueError("Expected one configured GlimmerTests target")
    references = set()
    for phase_id in targets[0]["buildPhases"]:
        phase = objects[phase_id]
        if phase["isa"] == "PBXSourcesBuildPhase":
            references.update(objects[entry]["fileRef"] for entry in phase["files"])
    paths, visited = {}, set()
    def visit(identifier, parent):
        if identifier in visited:
            raise ValueError(f"Repeated project group membership: {identifier}")
        visited.add(identifier)
        item = objects[identifier]
        tree = item.get("sourceTree", "<group>")
        if tree not in ("<group>", "SOURCE_ROOT"):
            return
        base = directory if tree == "SOURCE_ROOT" else parent
        path = (base / item.get("path", "")).resolve()
        if item["isa"] == "PBXGroup":
            for child in item.get("children", []):
                visit(child, path)
        elif item["isa"] == "PBXFileReference":
            paths[identifier] = path
    visit(objects[project["rootObject"]]["mainGroup"], directory)
    if not references or references - paths.keys():
        raise ValueError("Cannot resolve the complete configured test source set")
    sources = {paths[key] for key in references}
    if any(not path.is_relative_to(directory.parent.resolve()) for path in sources):
        raise ValueError("Configured test sources must stay inside this checkout")
    return sources


def render_suites(root=ROOT):
    directory = root / "iOS"
    project = json.loads(output(["plutil", "-convert", "json", "-o", "-", str(directory / "Glimmer.xcodeproj/project.pbxproj")]))
    suites = set()
    for path in configured_test_sources(project, directory):
        if path.suffix == ".swift":
            suites.update(re.findall(r"\b(?:struct|class)\s+(\w*RenderTests)\b", path.read_text()))
    if not suites:
        raise ValueError("No render suites found; refusing an empty or incomplete iOS partition")
    return sorted(suites)


def test_flags(diagnostic_retry=False):
    if diagnostic_retry:
        return ["-retry-tests-on-failure", "-test-iterations", "2"]
    return []


def filters(shard, root=ROOT):
    if shard == "core":
        return ["-only-testing:GlimmerTests", *[f"-skip-testing:GlimmerTests/{suite}" for suite in render_suites(root)]]
    if shard == "render":
        return [*[f"-only-testing:GlimmerTests/{suite}" for suite in render_suites(root)], "-only-testing:GlimmerUITests"]
    return []


@contextmanager
def simulator():
    command = [os.environ["GLIMMER_SIMCTL"]] if os.environ.get("GLIMMER_SIMCTL") else ["xcrun", "simctl"]
    sdk = output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"])
    try:
        runtimes = json.loads(output([*command, "list", "runtimes", "--json"], timeout=20))["runtimes"]
    except subprocess.TimeoutExpired as error:
        raise ValueError("simctl did not respond in 20s. Repair the selected Xcode/CoreSimulator setup; no toolchain was substituted.") from error
    def version(value):
        return tuple((value.split(".") + ["0", "0"])[:3])
    runtime = next((item["identifier"] for item in runtimes if item.get("isAvailable")
                    and item.get("platform") == "iOS" and version(item["version"]) == version(sdk)), None)
    if not runtime:
        raise ValueError(f"Install the iOS {sdk} Simulator runtime for Xcode 26.6 before running this shard.")
    device = output([*command, "create", f"Glimmer CI {uuid.uuid4()}",
                     "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime])
    try:
        subprocess.run([*command, "boot", device], check=True, timeout=60)
        subprocess.run([*command, "bootstatus", device, "-b"], check=True, timeout=180)
        yield f"platform=iOS Simulator,id={device}"
    finally:
        subprocess.run([*command, "shutdown", device], check=False, timeout=30)
        subprocess.run([*command, "delete", device], check=True, timeout=30)


def run(command, log, timeout=2400):
    print("+ " + " ".join(command), flush=True)
    started = time.monotonic()
    with log.open("w") as stream:
        process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, start_new_session=True)
        def relay():
            with process.stdout:
                for line in process.stdout:
                    stream.write(line)
                    stream.flush()
                    print(line, end="", flush=True)
        reader = Thread(target=relay, daemon=True)
        reader.start()
        try:
            status = process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            status = 124
        reader.join(timeout=10)
        if status == 124:
            stream.write(f"\nExecution exceeded {timeout}s or was interrupted; process group terminated.\n")
    text = log.read_text(errors="replace")
    print(f"Elapsed: {time.monotonic() - started:.1f}s; log: {log}", flush=True)
    return status or (1 if re.search(r"(^|\s)warning:", text) else 0)


def manifests(derived, scheme, clear=False):
    paths = sorted((derived / "Build/Products").glob(f"{scheme}_*.xctestrun"))
    if clear:
        for path in paths:
            path.unlink()
    elif len(paths) != 1:
        raise ValueError(f"Expected one {scheme} test manifest in {derived}; rebuild this shard")


def ios(args):
    if not (ROOT / "iOS/Makefile").exists():
        raise ValueError("This checkout has no iOS app")
    scheme = "Glimmer-iOS"
    folder = ROOT / "iOS/build/ci" / args.shard
    folder.mkdir(parents=True, exist_ok=True)
    derived = ROOT / "iOS/build/ci/DerivedData"
    selection = filters(args.shard)
    make = ["make", "-C", "iOS", f"SCHEME={scheme}", f"DERIVED={derived}"]
    if not args.run_only:
        manifests(derived, scheme, clear=True)
        status = run([*make, "test-build", "TEST_DESTINATION=generic/platform=iOS Simulator",
                      "TEST_FLAGS=-enableCodeCoverage YES"], folder / "build.log", 900)
        if status:
            subprocess.run([sys.executable, "scripts/ci-test-results.py", args.shard, str(folder / "missing.xcresult"),
                            str(folder / "build.log"), str(status)], check=True)
        if status:
            return status
        manifests(derived, scheme)
        if args.build_only:
            return 0
    manifests(derived, scheme)
    result = folder / f"{uuid.uuid4()}.xcresult"
    with simulator() as destination:
        flags = ["-enableCodeCoverage", "YES", "-resultBundlePath", str(result), *test_flags(args.diagnostic_retry), *selection]
        status = run([*make, "test-run", f"TEST_DESTINATION={destination}", "TEST_FLAGS=" + " ".join(flags)], folder / "test.log")
    status = status or receipt_status(result)
    if not status:
        with (folder / "coverage.json").open("w") as stream:
            subprocess.run(["xcrun", "xccov", "view", "--report", "--json", str(result)], stdout=stream, check=True)
        with (folder / "coverage.txt").open("w") as stream:
            subprocess.run(["xcrun", "xccov", "view", "--report", str(result)], stdout=stream, check=True)
    subprocess.run([sys.executable, "scripts/ci-test-results.py", args.shard, str(result), str(folder / "test.log"),
                    str(status), "--coverage", str(folder / "coverage.txt")], check=True)
    return status


def validate_test_result(summary, journeys=False):
    passed, failed = summary.get("passedTests"), summary.get("failedTests")
    if type(passed) is not int or passed <= 0 or type(failed) is not int or failed != 0:
        raise ValueError("Test evidence must contain positive passed tests and zero failures")
    if journeys and (summary.get("skippedTests", 0) or summary.get("expectedFailures", 0)):
        raise ValueError("Journey evidence must contain no skips or expected failures")


def receipt_status(result, journeys=False):
    try:
        summary = json.loads(output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], 60))
        result.with_suffix(".json").write_text(json.dumps(summary, indent=2) + "\n")
        validate_test_result(summary, journeys)
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        message = f"Invalid test receipt {result}: {error}"
        print(message, file=sys.stderr)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
                stream.write(f"### Test receipt rejected\n\n{message}\n")
        return 1


def completion_status(status, diagnostic_retry):
    if diagnostic_retry:
        print("Diagnostic retry results cannot qualify a candidate; a clean first attempt is required.")
        return status or 2
    return status


def journeys():
    folder = ROOT / "build/logs/journeys"
    folder.mkdir(parents=True, exist_ok=True)
    sdk = output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"])
    os.environ["JOURNEY_RUNTIME"] = "com.apple.CoreSimulator.SimRuntime.iOS-" + sdk.replace(".", "-")
    os.environ["JOURNEY_DEVICE"] = "all"
    os.environ["JOURNEY_APPEARANCE"] = "all"
    for name in ("JOURNEY_PHONE_ID", "JOURNEY_IPAD_ID"):
        os.environ.pop(name, None)
    status = 0
    for script in ("mac-controller-journeys", "ios-touch-journeys"):
        path = ROOT / f"scripts/{script}.sh"
        if not path.exists():
            raise ValueError(f"Missing journey runner: {path}")
        log = folder / f"{script}.log"
        results = folder / f"{script}-{uuid.uuid4()}"
        os.environ["JOURNEY_RESULTS"] = str(results)
        os.environ["JOURNEY_DERIVED"] = str(ROOT / "build/ci-journeys" / script)
        attempt = run(["bash", str(path)], log, 2400)
        status = status or attempt
        receipts = sorted(results.glob("*.xcresult"))
        expected = 4 if script.startswith("ios") else 2
        if len(receipts) != expected:
            print(f"Incomplete journey matrix: expected {expected} result bundles, found {len(receipts)}", file=sys.stderr)
            status = 1
        for result in receipts:
            result_status = attempt or receipt_status(result, journeys=True)
            status = status or result_status
            subprocess.run([sys.executable, "scripts/ci-test-results.py", "journeys", str(result), str(log), str(result_status)], check=True)
    return status


def main():
    os.chdir(ROOT)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("shard", choices=("core", "render", "journeys", "mac"))
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--build-only", action="store_true")
    group.add_argument("--run-only", action="store_true")
    group.add_argument("--validate-result", type=Path, help="Validate an existing test receipt without selecting a build toolchain")
    parser.add_argument("--diagnostic-retry", action="store_true", help="Retry once for diagnosis; always exits nonzero and is forbidden in hosted CI")
    args = parser.parse_args()
    try:
        if args.diagnostic_retry and (os.environ.get("GITHUB_ACTIONS") == "true" or args.build_only
                                      or args.validate_result or args.shard == "journeys"):
            raise ValueError("Diagnostic retries are local-only test runs for core, render or mac")
        if args.validate_result:
            return receipt_status(args.validate_result, journeys=args.shard == "journeys")
        toolchain()
        if args.shard == "journeys":
            if args.build_only or args.run_only:
                raise ValueError("Journey runners always build and execute the full device/appearance matrix")
            return journeys()
        if args.shard != "mac":
            return completion_status(ios(args), args.diagnostic_retry)
        folder = ROOT / "build/logs"
        folder.mkdir(parents=True, exist_ok=True)
        status = 0
        if not args.run_only:
            manifests(ROOT / "build", "Glimmer", clear=True)
            status = run(["make", "test-build", "COVERAGE=1"], folder / "test-build.log", 900)
        if status:
            return status
        manifests(ROOT / "build", "Glimmer")
        if args.build_only:
            return 0
        status = run(["make", "test-run", "COVERAGE=1", "TEST_FLAGS=" + " ".join(test_flags(args.diagnostic_retry))], folder / "mac.log")
        status = status or receipt_status(ROOT / "build/coverage/swift/glimmer.xcresult")
        subprocess.run([sys.executable, "scripts/ci-test-results.py", "mac", "build/coverage/swift/glimmer.xcresult",
                        str(folder / "mac.log"), str(status), "--coverage", "build/coverage/swift/summary.md"], check=True)
        return completion_status(status, args.diagnostic_retry)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        message = f"CI prerequisite or execution failed: {error}"
        print(message, file=sys.stderr)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
                stream.write(f"### {args.shard}: execution failed\n\n{message}\n\nReproduce: `make ci-local SHARD={args.shard}`\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
