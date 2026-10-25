#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Require the iOS consumer to build this checkout's complete engine package."""

import argparse
import importlib.util
from pathlib import Path
import subprocess
import sys

SPEC = importlib.util.spec_from_file_location("engine_boundary", Path(__file__).with_name("check-engine-boundary.py"))
BOUNDARY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOUNDARY)


SHARED_SOAK_SOURCES = {
    f"../EnginePackageTests/{name}.swift" for name in (
        "AudioSoakTests", "InputSoakTests", "SessionSoakTests", "SoakInputBackend", "SoakTransport"
    )
}


def validate_project(project, expected):
    objects = project["objects"]
    references = {key: item for key, item in objects.items()
                  if item["isa"] in ("XCLocalSwiftPackageReference", "XCRemoteSwiftPackageReference")}
    if len(references) != 1:
        raise ValueError("iOS must have one local engine package reference")
    package_id, package = next(iter(references.items()))
    if package["isa"] != "XCLocalSwiftPackageReference" or package.get("relativePath") != "..":
        raise ValueError("iOS engine package must be the repository root (..), never a remote pin or override")
    if objects[project["rootObject"]].get("packageReferences") != [package_id]:
        raise ValueError("iOS project must use its local engine reference")
    products = [(key, item) for key, item in objects.items() if item["isa"] == "XCSwiftPackageProductDependency"]
    if len(products) != 1 or products[0][1].get("package") != package_id or \
            products[0][1].get("productName") != "GlimmerEngine":
        raise ValueError("iOS must consume the canonical GlimmerEngine product")
    product_id = products[0][0]
    paths = BOUNDARY.file_paths(project)
    targets = {item["name"]: item for item in objects.values() if item["isa"] == "PBXNativeTarget"}
    if set(targets) != set(expected):
        raise ValueError("Unexpected iOS native targets")
    for name, target in targets.items():
        actual = set(BOUNDARY.target_sources(target, objects, paths))
        if actual != expected[name]:
            raise ValueError(f"iOS {name} source membership mismatch: missing={sorted(expected[name] - actual)}, "
                             f"unexpected={sorted(actual - expected[name])}")
    app = targets["Glimmer"]
    if app.get("packageProductDependencies") != [product_id]:
        raise ValueError("iOS app must depend on GlimmerEngine exactly once")
    linked = [objects[entry].get("productRef") for phase in app["buildPhases"]
              if objects[phase]["isa"] == "PBXFrameworksBuildPhase" for entry in objects[phase]["files"]]
    if linked.count(product_id) != 1:
        raise ValueError("iOS app must link GlimmerEngine exactly once")


def expected_sources(root):
    ios = root / "iOS"
    expected = {name: {str(path.relative_to(ios)) for path in (ios / name).rglob("*.swift")}
                for name in ("Glimmer", "GlimmerTests", "GlimmerUITests")}
    expected["Glimmer"].update(f"../Glimmer/Stream/{name}.swift" for name in (
        "StatsOverlayLayer", "StatsOverlayLayer+Rows", "StatsOverlayLayer+Traces", "StatsOverlayLayer+Platform"
    ))
    expected["GlimmerTests"].add("../GlimmerTests/VideoColorPatternTests.swift")
    expected["Glimmer"].update("../" + str(path.relative_to(root))
                               for path in (root / "Glimmer/ControllerLayouts").glob("*.swift"))
    expected["GlimmerTests"].update("../GlimmerTests/" + name for name in
                                  ["ControllerLayoutRenderTests.swift", "ControllerLayoutCaptureTests.swift",
                                   "ControllerDiagramTests.swift"])
    expected["GlimmerTests"].update("../EnginePackageTests/" + name for name in
                                  ["ControllerMappingTests.swift", "ControllerLayoutPersistenceTests.swift",
                                   "ControllerLayoutEscapeTests.swift"])
    # These transport fakes and session tests also compile in the Mac test target.
    shared = ("BitrateActuatorTests.swift", "FakeSunshine.swift", "InputRecordingBackend.swift",
              "BandwidthPolicyTests.swift", "BandwidthActuatorTests.swift",
              "OpusDecoderTests.swift", "SurroundToneData.swift", "VideoDepacketizerRecoveryTests.swift")
    for name in shared:
        if not (root / "GlimmerTests" / name).is_file():
            raise ValueError(f"Missing shared test source: {name}")
        expected["GlimmerTests"].add(f"../GlimmerTests/{name}")
    if any(not sources for sources in expected.values()):
        raise ValueError("Missing iOS app or test sources")
    expected["GlimmerTests"].update(SHARED_SOAK_SOURCES)
    if any(not (ios / source).is_file() for source in SHARED_SOAK_SOURCES):
        raise ValueError("Missing shared soak test sources")
    return expected


def check(root):
    ios = root / "iOS"
    expected = expected_sources(root)
    validate_project(BOUNDARY.load_project(ios / "Glimmer.xcodeproj/project.pbxproj"), expected)
    lock = ios / "Glimmer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    if lock.exists():
        raise ValueError("iOS must not keep a separate engine package lock")
    return sum(map(len, expected.values()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    args = parser.parse_args()
    try:
        count = check(args.repo.resolve())
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"iOS boundary check failed: {error}", file=sys.stderr)
        return 1
    print(f"iOS boundary verified: {count} native sources, same-checkout engine dependency")
    return 0


if __name__ == "__main__":
    sys.exit(main())
