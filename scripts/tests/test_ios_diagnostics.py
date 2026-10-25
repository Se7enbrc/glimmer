# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Artifact inspection fails closed on flavour or compiled-content mismatches."""

import importlib
from pathlib import Path
import sys
import unittest

from fixture_git import FixtureTestCase

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
inspection = importlib.import_module('check-ios-diagnostics')


class DiagnosticsInspectionTests(FixtureTestCase):
    def test_production_rejects_each_diagnostic_marker(self):
        for marker in inspection.COMPONENTS + inspection.SURFACES:
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                inspection.inspect_bytes(b'prefix' + marker + b'\x00', 'production')
        self.assertEqual(inspection.inspect_bytes(b'normal stream control', 'production'), [])

    def test_beta_requires_every_recording_component(self):
        payload = b'\x00'.join(inspection.COMPONENTS) + b'\x00'
        self.assertEqual(len(inspection.inspect_bytes(payload, 'beta')), len(inspection.COMPONENTS))
        for marker in inspection.COMPONENTS:
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                inspection.inspect_bytes(payload.replace(marker, b''), 'beta')

    def test_source_maps_and_empty_seam_names_are_not_type_implementations(self):
        payload = (b'AudioPipelineTelemetry.swift\x00DisplayTelemetrySnapshot\x00'
                   b'21stopTelemetryExporteryyF\x00')
        self.assertEqual(inspection.inspect_bytes(payload, 'production'), [])
        with self.assertRaises(ValueError):
            inspection.inspect_bytes(b'17TelemetryExporterC', 'production')

    def test_unknown_flavour_is_never_accepted(self):
        for flavour in ('', 'sandbox', 'testflight', None):
            with self.subTest(flavour=flavour), self.assertRaises(ValueError):
                inspection.inspect_bytes(b'', flavour)


if __name__ == '__main__':
    unittest.main()
