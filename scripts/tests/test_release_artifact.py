# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Release handoffs reject tampering, wrong producers and unsafe bundle archives."""

import copy
import io
import json
import os
from pathlib import Path
import sys
import subprocess
import zipfile
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import release_artifact as artifact
import release_download
from release_download import check_metadata

SHA = 'a' * 40


class ReleaseArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.handoff = self.root / 'handoff'
        self.handoff.mkdir()
        self.payload = self.handoff / 'Glimmer.app.tar.gz'
        self.payload.write_bytes(b'unsigned fixture')
        env = patch.dict(os.environ, GITHUB_REPOSITORY='Se7enbrc/glimmer', GITHUB_RUN_ID='12',
                         GITHUB_RUN_ATTEMPT='1', EXPECTED_SHA=SHA, RC_TAG='2026.10.6-rc.1',
                         GITHUB_OUTPUT=str(self.root / 'outputs'))
        env.start()
        self.addCleanup(env.stop)
        artifact.seal(self.handoff, 'unsigned')
        self.manifest = artifact.digest(self.handoff / 'manifest.json')

    def verify(self):
        return artifact.verify(self.handoff, 'unsigned', self.manifest, '1')

    def test_same_run_can_resume_from_explicit_producing_attempt(self):
        self.verify()
        with patch.dict(os.environ, GITHUB_RUN_ATTEMPT='2'):
            self.verify()
        with self.assertRaises(ValueError):
            artifact.verify(self.handoff, 'unsigned', self.manifest, '2')

    def test_other_run_source_repository_tag_or_attempt_fails_closed(self):
        for key, value in {'GITHUB_RUN_ID': '13', 'EXPECTED_SHA': 'b' * 40,
                           'GITHUB_REPOSITORY': 'fork/glimmer', 'RC_TAG': '2026.10.6-rc.2'}.items():
            with self.subTest(key=key), patch.dict(os.environ, {key: value}), self.assertRaises(ValueError):
                self.verify()
        with self.assertRaises(ValueError):
            artifact.verify(self.handoff, 'unsigned', self.manifest, '')
        with self.assertRaises(ValueError):
            artifact.verify(self.handoff, 'signed', self.manifest, '1')

    def test_modified_missing_extra_and_symlink_payloads_are_rejected(self):
        for contents in (b'changed', b''):
            self.payload.write_bytes(contents)
            with self.assertRaises(ValueError):
                self.verify()
        self.payload.unlink()
        with self.assertRaises(ValueError):
            self.verify()
        target = self.root / 'target'
        target.write_bytes(b'unsigned fixture')
        self.payload.symlink_to(target)
        with self.assertRaises(ValueError):
            self.verify()
        self.payload.unlink()
        self.payload.write_bytes(b'unsigned fixture')
        (self.handoff / 'extra.sh').write_text('not executable')
        with self.assertRaises(ValueError):
            self.verify()

    def test_rewriting_manifest_cannot_hide_tampered_bytes(self):
        path = self.handoff / 'manifest.json'
        data = json.loads(path.read_text())
        self.payload.write_bytes(b'changed')
        data['hashes'][self.payload.name] = artifact.digest(self.payload)
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'manifest digest'):
            self.verify()

    def archive(self, entries):
        path = self.root / 'bundle.tar.gz'
        with tarfile.open(path, 'w:gz') as bundle:
            for name, kind, value in entries:
                entry = tarfile.TarInfo(name)
                entry.type = kind
                entry.mode = 0o755
                if kind == tarfile.REGTYPE:
                    entry.size = len(value)
                    bundle.addfile(entry, io.BytesIO(value))
                else:
                    entry.linkname = value
                    bundle.addfile(entry)
        return path

    def test_bundle_preserves_executable_modes_and_internal_framework_links(self):
        path = self.archive([('Glimmer.app/Contents/MacOS/Glimmer', tarfile.REGTYPE, b'inert'),
                             ('Glimmer.app/Versions/B/Resource', tarfile.REGTYPE, b'resource'),
                             ('Glimmer.app/Versions/Current', tarfile.SYMTYPE, 'B')])
        destination = self.root / 'destination'
        artifact.unpack(path, destination)
        self.assertTrue(os.access(destination / 'Glimmer.app/Contents/MacOS/Glimmer', os.X_OK))
        self.assertEqual((destination / 'Glimmer.app/Versions/Current/Resource').read_bytes(), b'resource')
        with self.assertRaises(ValueError):
            artifact.unpack(path, destination)

    def test_unsafe_paths_links_devices_and_duplicate_entries_are_rejected(self):
        cases = [
            [('outside', tarfile.REGTYPE, b'x')],
            [('/Glimmer.app/file', tarfile.REGTYPE, b'x')],
            [('Glimmer.app/../outside', tarfile.REGTYPE, b'x')],
            [('Glimmer.app/link', tarfile.SYMTYPE, '../../outside')],
            [('Glimmer.app/link', tarfile.LNKTYPE, 'Glimmer.app/file')],
            [('Glimmer.app/device', tarfile.CHRTYPE, '')],
            [('Glimmer.app/link', tarfile.SYMTYPE, 'inside'),
             ('Glimmer.app/link/file', tarfile.REGTYPE, b'x')],
            [('Glimmer.app/file', tarfile.REGTYPE, b'x')] * 2,
        ]
        for index, entries in enumerate(cases):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                artifact.unpack(self.archive(entries), self.root / f'output-{index}')
            self.assertFalse((self.root / f'output-{index}').exists())

    def test_github_artifact_metadata_binds_id_name_source_run_and_expiry(self):
        data = {'id': 100, 'name': f'unsigned-12-1-{SHA}', 'expired': False,
                'workflow_run': {'id': 12, 'head_sha': SHA}}
        check_metadata(data, 'unsigned', '100', '1')
        for key, value in [('id', 101), ('name', f'unsigned-12-2-{SHA}'), ('expired', True),
                           ('workflow_run', {'id': 13, 'head_sha': SHA}),
                           ('workflow_run', {'id': 12, 'head_sha': 'b' * 40})]:
            changed = copy.deepcopy(data)
            changed[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                check_metadata(changed, 'unsigned', '100', '1')

    def test_download_accepts_flat_handoff_and_rejects_container_traversal(self):
        metadata = {'id': 100, 'name': f'unsigned-12-1-{SHA}', 'expired': False,
                    'workflow_run': {'id': 12, 'head_sha': SHA}}
        for index, name in enumerate(('payload', '../outside', '/absolute')):
            runner = self.root / f'runner-{index}'
            runner.mkdir()
            payload = io.BytesIO()
            with zipfile.ZipFile(payload, 'w') as archive:
                archive.writestr(name, b'fixture')

            def response(args, **kwargs):
                if args[-1].endswith('/zip'):
                    kwargs['stdout'].write(payload.getvalue())
                    return subprocess.CompletedProcess(args, 0)
                return subprocess.CompletedProcess(args, 0, json.dumps(metadata))

            with patch.dict(os.environ, RUNNER_TEMP=str(runner)), \
                    patch.object(release_download.subprocess, 'run', side_effect=response):
                if name == 'payload':
                    release_download.download('unsigned', '100', '1')
                    self.assertEqual((runner / 'unsigned/payload').read_bytes(), b'fixture')
                else:
                    with self.assertRaises(ValueError):
                        release_download.download('unsigned', '100', '1')
                    self.assertEqual(list((runner / 'unsigned').iterdir()), [])
            self.assertFalse((runner / 'outside').exists())


if __name__ == '__main__':
    unittest.main()
