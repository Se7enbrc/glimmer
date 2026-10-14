#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Keep Xcode and SwiftPM source ownership aligned across the engine boundary."""

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

NATIVE_MODULES = {"Glimmer", "AppKit", "UIKit", "SwiftUI", "IOKit", "GameController", "CoreHaptics"}
IMPORT = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+"
                    r"(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?(\w+)", re.M)


def unique(values, description):
    duplicates = sorted(value for value, count in Counter(values).items() if count > 1)
    if duplicates:
        raise ValueError(f"Duplicate {description}: {', '.join(duplicates)}")


def load_project(path):
    text = path.read_text()
    identifiers = re.findall(r"^\s*([A-Z0-9]+)(?: /\*.*?\*/)? = \{\s*isa =", text, re.M)
    unique(identifiers, "PBX object IDs")
    project = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))
    if set(identifiers) != set(project["objects"]):
        raise ValueError("Cannot account for every PBX object declaration")
    return project


def file_paths(project):
    objects = project["objects"]
    paths = {}
    visited = set()

    def visit(identifier, parent):
        if identifier in visited:
            raise ValueError(f"Repeated or cyclic group membership: {identifier}")
        visited.add(identifier)
        item = objects[identifier]
        tree = item.get("sourceTree", "<group>")
        if tree not in ("<group>", "SOURCE_ROOT"):
            return
        path = os.path.normpath(os.path.join(parent if tree == "<group>" else "", item.get("path", "")))
        if item["isa"] == "PBXGroup":
            for child in item.get("children", []):
                visit(child, path)
        elif item["isa"] == "PBXFileReference":
            paths[identifier] = path

    visit(objects[project["rootObject"]]["mainGroup"], "")
    unique([path for path in paths.values() if path.startswith("GlimmerEngine/")
            and path.endswith(".swift")], "engine file references")
    return paths


def target_sources(target, objects, paths):
    unique(target["buildPhases"], "target build phases")
    sources = []
    for phase_id in target["buildPhases"]:
        phase = objects[phase_id]
        if phase["isa"] != "PBXSourcesBuildPhase":
            continue
        unique(phase["files"], "source build entries")
        for build_id in phase["files"]:
            build = objects[build_id]
            reference = build["fileRef"]
            if reference not in paths:
                raise ValueError(f"Unresolved source reference: {reference}")
            if paths[reference].startswith("GlimmerEngine/") and (build.get("platformFilter")
                                                                 or build.get("platformFilters")):
                raise ValueError(f"Engine source has platform-specific membership: {paths[reference]}")
            sources.append(paths[reference])
    unique(sources, "compiled source paths")
    return sources


def validate_graph(project, expected):
    objects = project["objects"]
    paths = file_paths(project)
    pairs = [(key, value) for key, value in objects.items() if value["isa"] == "PBXNativeTarget"]
    unique([value["name"] for _, value in pairs], "target names")
    targets = {value["name"]: (key, value) for key, value in pairs}
    engine_id, engine = targets["GlimmerEngine"]
    if engine.get("dependencies") or engine.get("packageProductDependencies"):
        raise ValueError("Engine must not depend on app targets or package products")
    validate_configurations((objects[project["rootObject"]], engine), objects)
    for name, (_, target) in targets.items():
        actual = set(target_sources(target, objects, paths))
        if name in expected and actual != expected[name]:
            missing = sorted(expected[name] - actual)
            extra = sorted(actual - expected[name])
            raise ValueError(f"{name} source membership mismatch; missing={missing}; unexpected={extra}")
        if name != "GlimmerEngine" and any(path.startswith("GlimmerEngine/") for path in actual):
            raise ValueError(f"Engine source compiled by native target {name}")
    for name in ("Glimmer", "GlimmerTests"):
        target = targets[name][1]
        dependencies = [objects[key].get("target") for key in target.get("dependencies", [])]
        if dependencies.count(engine_id) != 1:
            raise ValueError(f"{name} must depend on the engine exactly once")
        linked = phase_references(target, objects, "PBXFrameworksBuildPhase")
        if linked.count(engine["productReference"]) != 1:
            raise ValueError(f"{name} must link the engine exactly once")
    embedded = phase_references(targets["Glimmer"][1], objects, "PBXCopyFilesBuildPhase", "10")
    if embedded.count(engine["productReference"]) != 1:
        raise ValueError("App must embed the engine framework exactly once")
    return engine_id


def validate_configurations(owners, objects):
    for owner in owners:
        configurations = objects[owner["buildConfigurationList"]]["buildConfigurations"]
        unique(configurations, "build configuration entries")
        for identifier in configurations:
            configuration = objects[identifier]
            if configuration.get("baseConfigurationReference"):
                raise ValueError("Engine/project config files need an explicit source-filter audit")
            for key, value in configuration.get("buildSettings", {}).items():
                if key.split("[", 1)[0] in ("EXCLUDED_SOURCE_FILE_NAMES", "INCLUDED_SOURCE_FILE_NAMES") and value:
                    raise ValueError(f"Engine/project configuration filters source membership: {key}")


def phase_references(target, objects, kind, destination=None):
    references = []
    for key in target["buildPhases"]:
        phase = objects[key]
        if phase["isa"] == kind and (destination is None or phase.get("dstSubfolderSpec") == destination):
            references.extend(objects[key].get("fileRef") for key in phase.get("files", []))
    return references


def validate_package(package):
    targets = [target for target in package["targets"] if target["name"] == "GlimmerEngine"]
    if len(targets) != 1:
        raise ValueError("SwiftPM must have exactly one engine target")
    target = targets[0]
    if (target["type"] != "regular" or target.get("path") != "GlimmerEngine"
            or target.get("dependencies") or target.get("exclude") or target.get("pluginUsages") or target.get("resources")
            or target.get("sources") is not None):
        raise ValueError("SwiftPM engine must compile the complete engine directory without external dependencies")


def validate_imports(path, text):
    forbidden = set(IMPORT.findall(text)) & NATIVE_MODULES
    if forbidden:
        raise ValueError(f"Native or reverse app import in {path}: {', '.join(sorted(forbidden))}")


def validate_scheme(path, engine_id):
    scheme = ET.parse(path).getroot()
    entries = scheme.findall("./BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference")
    if len(entries) != 1 or entries[0].get("BlueprintIdentifier") != engine_id:
        raise ValueError("Shared engine scheme must build the canonical framework target")
    if entries[0].get("ReferencedContainer") != "container:Glimmer.xcodeproj":
        raise ValueError("Shared engine scheme references another project")


def check(root):
    expected = {}
    for target, directories in {"GlimmerEngine": ("GlimmerEngine",), "Glimmer": ("Glimmer",),
                                "GlimmerTests": ("GlimmerTests", "EnginePackageTests")}.items():
        expected[target] = {str(path.relative_to(root)) for directory in directories
                            for path in (root / directory).rglob("*.swift")}
        if not expected[target]:
            raise ValueError(f"No source files found for {target}")
    # The app and hostless helper tests intentionally compile the native helper contract.
    expected["Glimmer"].update(("helper/Protocol.swift", "Glimmer/BuildInfo.generated.swift"))
    expected["GlimmerTests"].update(("helper/Protocol.swift", "helper/AWDLSuppressor.swift", "helper/HelperService.swift",
                                     "Glimmer/AWDLStreamLease.swift", "Glimmer/AWDLProcess.swift"))
    engine_id = validate_graph(load_project(root / "Glimmer.xcodeproj/project.pbxproj"), expected)
    package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], cwd=root))
    validate_package(package)
    for path in expected["GlimmerEngine"]:
        validate_imports(path, (root / path).read_text())
    validate_scheme(root / "Glimmer.xcodeproj/xcshareddata/xcschemes/GlimmerEngine.xcscheme", engine_id)
    return len(expected["GlimmerEngine"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    arguments = parser.parse_args()
    try:
        count = check(arguments.repo.resolve())
    except (ValueError, OSError, KeyError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"Engine boundary check failed: {error}", file=sys.stderr)
        return 1
    print(f"Engine boundary verified: {count} shared sources, unique ownership, dependency and scheme checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
