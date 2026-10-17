# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("local_project", ROOT / "scripts/local-project.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LocalProjectTests(unittest.TestCase):
    def test_override_preserves_tracked_project_and_uses_original_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "Glimmer.xcodeproj"
            schemes = project / "xcshareddata/xcschemes"
            schemes.mkdir(parents=True)
            original = (ROOT / "Glimmer.xcodeproj/project.pbxproj").read_text()
            (project / "project.pbxproj").write_text(original)
            (schemes / "Glimmer.xcscheme").write_text('container:Glimmer.xcodeproj')
            engine = root / 'engine with spaces'
            engine.mkdir()
            (engine / "Package.swift").write_text('// fixture')
            output = MODULE.local_project(root, engine)
            result = (output / "project.pbxproj").read_text()
            self.assertEqual((project / "project.pbxproj").read_text(), original)
            self.assertIn('isa = XCLocalSwiftPackageReference;', result)
            self.assertNotIn('isa = XCRemoteSwiftPackageReference;', result)
            self.assertIn(f'relativePath = "{engine.resolve()}";', result)
            self.assertIn(f'projectDirPath = "{root.resolve()}";', result)
            self.assertIn(f'container:{output.resolve()}',
                          (output / 'xcshareddata/xcschemes/Glimmer.xcscheme').read_text())

    def test_checkout_without_manifest_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "needs Package.swift"):
                MODULE.local_project(Path(temporary), Path(temporary))
