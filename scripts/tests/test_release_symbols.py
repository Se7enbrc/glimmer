# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Diagnostic symbols are matched to binaries and bound to the artifact identity."""

import json
from pathlib import Path
import sys
import tempfile
import unittest

from fixture_git import FixtureTestCase
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).parents[1]))
import release_symbols as symbols


class ReleaseSymbolsTests(FixtureTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'Glimmer.app'
        self.handoff = self.root / 'handoff'
        self.handoff.mkdir()
        self.identity = {'EXPECTED_SHA': 'a' * 40, 'RC_TAG': '2026.10.8-rc.1-diag',
                         'GITHUB_REPOSITORY': 'Se7enbrc/glimmer', 'GITHUB_RUN_ID': '12', 'GITHUB_RUN_ATTEMPT': '1'}
        for bundle, name in (('Glimmer.app.dSYM', 'Glimmer'), ('GlimmerEngine.framework.dSYM', 'GlimmerEngine')):
            dwarf = self.root / bundle / 'Contents/Resources/DWARF' / name
            dwarf.parent.mkdir(parents=True)
            dwarf.write_bytes(b'debug information fixture')
        self.ids = [['AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA', 'arm64']]

    def pack(self):
        with patch.object(symbols, 'uuids', return_value=self.ids):
            symbols.pack(self.app, self.handoff, self.identity)

    def test_matching_symbols_survive_handoff_with_uuid_and_source_identity(self):
        self.pack()
        destination = self.root / 'signed'
        destination.mkdir()
        receipt = symbols.carry(self.handoff, destination, '2026.10.8', self.identity)
        self.assertEqual(receipt['identity'], self.identity)
        self.assertEqual(receipt['images']['GlimmerEngine']['uuids'], self.ids)
        with zipfile.ZipFile(destination / receipt['archive']) as archive:
            self.assertEqual(len(archive.namelist()), 2)
            self.assertTrue(all('.dSYM/' in name for name in archive.namelist()))
        symbols.validate(destination, receipt['archive'], {**self.identity, 'GITHUB_RUN_ATTEMPT': '2'})

    def test_missing_or_mismatched_symbols_fail_before_persisting_manifest(self):
        with patch.object(symbols, 'uuids', side_effect=[self.ids, [['different', 'arm64']]]):
            with self.assertRaisesRegex(ValueError, 'does not match'):
                symbols.pack(self.app, self.handoff, self.identity)
        dwarf = self.root / 'GlimmerEngine.framework.dSYM/Contents/Resources/DWARF/GlimmerEngine'
        dwarf.unlink()
        with patch.object(symbols, 'uuids', return_value=self.ids), self.assertRaisesRegex(ValueError, 'requires'):
            symbols.pack(self.app, self.handoff, self.identity)
        self.assertFalse((self.handoff / symbols.MANIFEST).exists())

    def test_modified_archive_other_identity_and_future_attempt_fail_closed(self):
        self.pack()
        for key, value in (('EXPECTED_SHA', 'b' * 40), ('RC_TAG', '2026.10.8-rc.1'), ('GITHUB_RUN_ID', '13')):
            with self.subTest(key=key), self.assertRaises(ValueError):
                symbols.validate(self.handoff, symbols.ARCHIVE, {**self.identity, key: value})
        record = json.loads((self.handoff / symbols.MANIFEST).read_text())
        record['identity']['GITHUB_RUN_ATTEMPT'] = '2'
        (self.handoff / symbols.MANIFEST).write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'attempt'):
            symbols.validate(self.handoff, symbols.ARCHIVE, self.identity)
        record['identity']['GITHUB_RUN_ATTEMPT'] = '1'
        (self.handoff / symbols.MANIFEST).write_text(json.dumps(record))
        (self.handoff / symbols.ARCHIVE).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'digest'):
            symbols.validate(self.handoff, symbols.ARCHIVE, self.identity)
