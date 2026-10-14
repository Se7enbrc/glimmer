# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Project mutations must fail before an incomplete or reversed engine build ships."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("engine_boundary", Path(__file__).parents[1] / "check-engine-boundary.py")
BOUNDARY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOUNDARY)


def project_fixture():
    objects = {"ROOT": {"isa": "PBXProject", "mainGroup": "GROUP", "buildConfigurationList": "PROJECTCONFIGS"},
               "PROJECTCONFIGS": {"isa": "XCConfigurationList", "buildConfigurations": ["PROJECTCONFIG"]},
               "PROJECTCONFIG": {"isa": "XCBuildConfiguration", "buildSettings": {}},
               "ENGINECONFIGS": {"isa": "XCConfigurationList", "buildConfigurations": ["ENGINECONFIG"]},
               "ENGINECONFIG": {"isa": "XCBuildConfiguration", "buildSettings": {}},
               "GROUP": {"isa": "PBXGroup", "children": []},
               "PRODUCT": {"isa": "PBXFileReference", "sourceTree": "BUILT_PRODUCTS_DIR",
                           "path": "GlimmerEngine.framework"}}
    expected = {}
    for index, name in enumerate(("GlimmerEngine", "Glimmer", "GlimmerTests")):
        prefix = str(index)
        path = f"{name}/Source.swift"
        expected[name] = {path}
        objects["GROUP"]["children"].append(prefix + "FILE")
        objects[prefix + "FILE"] = {"isa": "PBXFileReference", "path": path, "sourceTree": "SOURCE_ROOT"}
        objects[prefix + "BUILD"] = {"isa": "PBXBuildFile", "fileRef": prefix + "FILE"}
        objects[prefix + "SOURCES"] = {"isa": "PBXSourcesBuildPhase", "files": [prefix + "BUILD"]}
        objects[prefix + "FRAMEWORK"] = {"isa": "PBXBuildFile", "fileRef": "PRODUCT"}
        objects[prefix + "LINK"] = {"isa": "PBXFrameworksBuildPhase", "files": [prefix + "FRAMEWORK"] if index else []}
        objects[prefix + "DEP"] = {"isa": "PBXTargetDependency", "target": "0TARGET"}
        objects[prefix + "TARGET"] = {"isa": "PBXNativeTarget", "name": name, "productReference": "PRODUCT",
                                      "buildPhases": [prefix + "SOURCES", prefix + "LINK"],
                                      "dependencies": [prefix + "DEP"] if index else []}
    objects["EMBED"] = {"isa": "PBXCopyFilesBuildPhase", "dstSubfolderSpec": "10", "files": ["1FRAMEWORK"]}
    objects["1TARGET"]["buildPhases"].append("EMBED")
    objects["0TARGET"]["buildConfigurationList"] = "ENGINECONFIGS"
    return {"rootObject": "ROOT", "objects": objects}, expected


class EngineBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.project, self.expected = project_fixture()
        self.objects = self.project["objects"]

    def check(self):
        return BOUNDARY.validate_graph(self.project, self.expected)

    def test_complete_project_preserves_single_engine_dependency(self):
        self.assertEqual(self.check(), "0TARGET")

    def test_missing_engine_source_fails(self):
        self.objects["0SOURCES"]["files"].clear()
        with self.assertRaisesRegex(ValueError, "membership mismatch"):
            self.check()

    def test_native_adapter_cannot_enter_engine_sources(self):
        self.objects["0SOURCES"]["files"].append("1BUILD")
        with self.assertRaisesRegex(ValueError, "unexpected=.*Glimmer/Source"):
            self.check()

    def test_engine_source_cannot_also_compile_in_app(self):
        self.objects["1SOURCES"]["files"].append("0BUILD")
        self.expected["Glimmer"].add("GlimmerEngine/Source.swift")
        with self.assertRaisesRegex(ValueError, "Engine source compiled by native"):
            self.check()

    def test_duplicate_build_entry_fails(self):
        self.objects["0SOURCES"]["files"].append("0BUILD")
        with self.assertRaisesRegex(ValueError, "Duplicate source build entries"):
            self.check()

    def test_two_build_entries_for_same_file_fail(self):
        self.objects["OTHERBUILD"] = dict(self.objects["0BUILD"])
        self.objects["0SOURCES"]["files"].append("OTHERBUILD")
        with self.assertRaisesRegex(ValueError, "Duplicate compiled source paths"):
            self.check()

    def test_duplicate_engine_file_reference_fails(self):
        self.objects["OTHERFILE"] = dict(self.objects["0FILE"])
        self.objects["GROUP"]["children"].append("OTHERFILE")
        with self.assertRaisesRegex(ValueError, "Duplicate engine file references"):
            self.check()

    def test_platform_filtered_engine_sources_fail(self):
        for filter_key, value in (("platformFilter", "macos"), ("platformFilters", ["macos"])):
            with self.subTest(filter_key=filter_key):
                self.setUp()
                self.objects["0BUILD"][filter_key] = value
                with self.assertRaisesRegex(ValueError, "platform-specific membership"):
                    self.check()

    def test_native_helper_may_share_reference_across_separate_targets(self):
        self.objects["HELPER"] = {"isa": "PBXFileReference", "path": "helper/Protocol.swift"}
        self.objects["OTHERHELPER"] = dict(self.objects["HELPER"])
        self.objects["GROUP"]["children"].extend(("HELPER", "OTHERHELPER"))
        self.check()

    def test_cyclic_group_fails(self):
        self.objects["GROUP"]["children"].append("GROUP")
        with self.assertRaisesRegex(ValueError, "cyclic group"):
            self.check()

    def test_unresolved_source_reference_fails(self):
        self.objects["GROUP"]["children"].remove("0FILE")
        with self.assertRaisesRegex(ValueError, "Unresolved source reference"):
            self.check()

    def test_reverse_target_dependency_fails(self):
        self.objects["0TARGET"]["dependencies"] = ["1DEP"]
        with self.assertRaisesRegex(ValueError, "must not depend"):
            self.check()

    def test_engine_and_inherited_project_source_filters_fail(self):
        for owner in ("ENGINECONFIG", "PROJECTCONFIG"):
            for key in ("EXCLUDED_SOURCE_FILE_NAMES", "EXCLUDED_SOURCE_FILE_NAMES[sdk=iphoneos*]",
                        "INCLUDED_SOURCE_FILE_NAMES[sdk=iphonesimulator*]"):
                with self.subTest(owner=owner, key=key):
                    self.setUp()
                    self.objects[owner]["buildSettings"][key] = "Source.swift"
                    with self.assertRaisesRegex(ValueError, "configuration filters source membership"):
                        self.check()

    def test_unaudited_configuration_file_cannot_hide_source_filters(self):
        for owner in ("ENGINECONFIG", "PROJECTCONFIG"):
            with self.subTest(owner=owner):
                self.setUp()
                self.objects[owner]["baseConfigurationReference"] = "CONFIGFILE"
                with self.assertRaisesRegex(ValueError, "explicit source-filter audit"):
                    self.check()

    def test_missing_dependency_link_and_embed_each_fail(self):
        for kind in ("dependency", "link", "embed"):
            with self.subTest(kind=kind):
                self.setUp()
                if kind == "dependency":
                    self.objects["1TARGET"]["dependencies"].clear()
                else:
                    self.objects["1LINK" if kind == "link" else "EMBED"]["files"].clear()
                with self.assertRaisesRegex(ValueError, "exactly once"):
                    self.check()

    def test_duplicate_object_ids_fail_before_plist_conversion(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "project.pbxproj"
            path.write_text("\t\tAA /* one */ = {isa = PBXGroup; };\n\t\tAA /* two */ = {isa = PBXGroup; };\n")
            with self.assertRaisesRegex(ValueError, "Duplicate PBX object IDs"):
                BOUNDARY.load_project(path)

    def test_package_cannot_exclude_sources_or_add_dependencies(self):
        target = {"name": "GlimmerEngine", "type": "regular", "path": "GlimmerEngine", "dependencies": []}
        BOUNDARY.validate_package({"targets": [target]})
        for change in ({"exclude": ["Audio"]}, {"sources": ["Protocol"]}, {"dependencies": ["Native"]},
                       {"path": "Glimmer"}, {"type": "binary"}, {"pluginUsages": ["Generator"]},
                       {"resources": [{"path": "Protocol", "rule": {"process": {}}}]}):
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "complete engine directory"):
                BOUNDARY.validate_package({"targets": [target | change]})

    def test_forbidden_imports_include_attributes_access_and_scoped_imports(self):
        for declaration in ("import Glimmer", "@testable import Glimmer", "public import AppKit",
                            "internal import Glimmer", "package import UIKit", "import SwiftUI", "import class AppKit.NSView",
                            "@preconcurrency import GameController", "@_spi(Internal) public import CoreHaptics"):
            with self.subTest(declaration=declaration), self.assertRaisesRegex(ValueError, "Native or reverse"):
                BOUNDARY.validate_imports("GlimmerEngine/Test.swift", declaration)
        BOUNDARY.validate_imports("GlimmerEngine/Test.swift", "import Foundation\nimport AVFoundation\nimport QuartzCore")

    def test_shared_scheme_cannot_build_app_instead(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "GlimmerEngine.xcscheme"
            path.write_text('<Scheme><BuildAction><BuildActionEntries><BuildActionEntry>'
                            '<BuildableReference BlueprintIdentifier="APP" ReferencedContainer="container:Glimmer.xcodeproj"/>'
                            '</BuildActionEntry></BuildActionEntries></BuildAction></Scheme>')
            with self.assertRaisesRegex(ValueError, "canonical framework"):
                BOUNDARY.validate_scheme(path, "0TARGET")


if __name__ == "__main__":
    unittest.main()
