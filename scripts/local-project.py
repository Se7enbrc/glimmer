#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Keep local engine overrides in ignored build output, never in the shared project."""

import argparse
from pathlib import Path
import re


def local_project(root, engine):
    engine = engine.resolve()
    if not (engine / "Package.swift").is_file():
        raise ValueError("The engine checkout needs Package.swift. Use the engine/spm worktree.")
    original = root / "Glimmer.xcodeproj"
    output = root / "build/GlimmerLocal.xcodeproj"
    project = (original / "project.pbxproj").read_text()
    pattern = r'isa = XCRemoteSwiftPackageReference;.*?repositoryURL = .*?;.*?requirement = \{.*?\};'
    escaped = str(engine).replace('\\', '\\\\').replace('"', '\\"')
    project, count = re.subn(pattern, lambda _: 'isa = XCLocalSwiftPackageReference;\n'
                           f'\t\t\trelativePath = "{escaped}";', project, flags=re.S)
    if count != 1:
        raise ValueError("Expected exactly one engine dependency in the shared project.")
    source_root = str(root.resolve()).replace('\\', '\\\\').replace('"', '\\"')
    project = project.replace('projectDirPath = "";', f'projectDirPath = "{source_root}";')
    output.mkdir(parents=True, exist_ok=True)
    (output / "project.pbxproj").write_text(project)
    schemes = output / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    for scheme in (original / "xcshareddata/xcschemes").glob("*.xcscheme"):
        (schemes / scheme.name).write_text(scheme.read_text().replace("container:Glimmer.xcodeproj", f"container:{output.resolve()}"))
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path)
    arguments = parser.parse_args()
    try:
        local_project(Path(__file__).resolve().parent.parent, arguments.engine)
    except ValueError as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
