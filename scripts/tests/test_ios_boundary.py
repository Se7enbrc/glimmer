# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""An iOS pin, copied engine source or incomplete target must fail verification."""

import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ios_boundary", ROOT / "scripts/check-ios-boundary.py")
BOUNDARY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOUNDARY)


class IOSBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = BOUNDARY.BOUNDARY.load_project(ROOT / "iOS/Glimmer.xcodeproj/project.pbxproj")
        cls.expected = BOUNDARY.expected_sources(ROOT)

    def setUp(self):
        self.value = copy.deepcopy(self.project)
        self.objects = self.value["objects"]

    def object(self, kind):
        return next(item for item in self.objects.values() if item["isa"] == kind)

    def test_canonical_checkout_passes(self):
        BOUNDARY.validate_project(self.value, self.expected)
        self.assertEqual(BOUNDARY.check(ROOT), sum(map(len, self.expected.values())))

    def test_remote_pin_is_rejected(self):
        package = self.object("XCLocalSwiftPackageReference")
        package.update(isa="XCRemoteSwiftPackageReference", repositoryURL="https://example.org/glimmer.git")
        with self.assertRaisesRegex(ValueError, "never a remote pin"):
            BOUNDARY.validate_project(self.value, self.expected)

    def test_other_checkout_is_rejected(self):
        self.object("XCLocalSwiftPackageReference")["relativePath"] = "../../old-engine"
        with self.assertRaisesRegex(ValueError, "repository root"):
            BOUNDARY.validate_project(self.value, self.expected)

    def test_duplicate_or_unused_package_is_rejected(self):
        self.objects["COPY"] = copy.deepcopy(self.object("XCLocalSwiftPackageReference"))
        with self.assertRaisesRegex(ValueError, "one local"):
            BOUNDARY.validate_project(self.value, self.expected)
        del self.objects["COPY"]
        self.objects[self.value["rootObject"]]["packageReferences"] = []
        with self.assertRaisesRegex(ValueError, "use its local"):
            BOUNDARY.validate_project(self.value, self.expected)

    def test_missing_source_is_rejected(self):
        self.object("PBXSourcesBuildPhase")["files"].pop()
        with self.assertRaisesRegex(ValueError, "source membership mismatch"):
            BOUNDARY.validate_project(self.value, self.expected)

    def test_each_shared_soak_source_is_required(self):
        paths = BOUNDARY.BOUNDARY.file_paths(self.value)
        for source in BOUNDARY.SHARED_SOAK_SOURCES:
            with self.subTest(source=source):
                value = copy.deepcopy(self.value)
                objects = value["objects"]
                for phase in objects.values():
                    if phase["isa"] == "PBXSourcesBuildPhase":
                        phase["files"] = [entry for entry in phase["files"]
                                          if paths[objects[entry]["fileRef"]] != source]
                with self.assertRaisesRegex(ValueError, "source membership mismatch"):
                    BOUNDARY.validate_project(value, self.expected)

    def test_compiling_engine_source_in_shell_is_rejected(self):
        reference = next(item for item in self.objects.values()
                         if item["isa"] == "PBXFileReference" and item.get("path", "").endswith(".swift"))
        reference.update(path="../GlimmerEngine/Audio/AudioDecoder.swift", sourceTree="SOURCE_ROOT")
        with self.assertRaisesRegex(ValueError, "source membership mismatch"):
            BOUNDARY.validate_project(self.value, self.expected)

    def test_wrong_product_is_rejected(self):
        self.object("XCSwiftPackageProductDependency")["productName"] = "OldEngine"
        with self.assertRaisesRegex(ValueError, "canonical GlimmerEngine"):
            BOUNDARY.validate_project(self.value, self.expected)

    def test_unlinked_product_is_rejected(self):
        product_id = next(key for key, item in self.objects.items() if item["isa"] == "XCSwiftPackageProductDependency")
        for item in self.objects.values():
            if item.get("productRef") == product_id:
                item["productRef"] = "MISSING"
        with self.assertRaisesRegex(ValueError, "link GlimmerEngine"):
            BOUNDARY.validate_project(self.value, self.expected)


if __name__ == "__main__":
    unittest.main()
