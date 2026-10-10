"""Exercise scanner installation without downloading or executing release binaries."""

import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "install-ci-scanner.sh"
SHA256 = "b8a3f496ec10f213bd2d2ad276625a773a2b284b5cc84993d24fc27db00d3493"


class CIScannerTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.bin = self.root / "commands"
        self.bin.mkdir()
        self.runner = self.root / "runner"
        self.runner.mkdir()
        self.github_path = self.root / "github_path"
        self.github_path.touch()
        self.archive = self.root / "fixture.tar.gz"
        with tarfile.open(self.archive, "w:gz") as archive:
            for name, contents in (("trufflehog", b"fixture scanner\n"), ("metadata", b"unused\n")):
                member = tarfile.TarInfo(name)
                member.size = len(contents)
                archive.addfile(member, io.BytesIO(contents))
        self.stub("uname", 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n')
        self.stub("curl", 'printf "%s\\n" "$@" > "$FIXTURE_CURL_ARGS"\n'
                  'while [ "$1" != --output ]; do shift; done\ncp "$FIXTURE_ARCHIVE" "$2"\n')
        self.stub("shasum", '[ "$*" = "-a 256 --check --status" ]\nread -r hash file\n'
                  '[ "$hash" = "$FIXTURE_EXPECTED_HASH" ] && [ -f "$file" ]\n')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -eu\n" + body)
        path.chmod(0o755)

    def run_installer(self, **overrides):
        environment = dict(os.environ, CI="true", RUNNER_TEMP=str(self.runner),
                           GITHUB_PATH=str(self.github_path),
                           PATH=f"{self.bin}:{os.environ['PATH']}",
                           FIXTURE_ARCHIVE=str(self.archive), FIXTURE_EXPECTED_HASH=SHA256,
                           FIXTURE_CURL_ARGS=str(self.root / "curl_args"))
        environment.update(overrides)
        return subprocess.run(["bash", str(SCRIPT)], env=environment, capture_output=True)

    def test_success_installs_only_scanner_and_cleans_download(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        binary = self.runner / "glimmer-tools/bin/trufflehog"
        self.assertEqual(binary.read_bytes(), b"fixture scanner\n")
        self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.github_path.read_text(), str(binary.parent) + "\n")
        self.assertEqual(list(self.runner.iterdir()), [self.runner / "glimmer-tools"])
        args = (self.root / "curl_args").read_text().splitlines()
        self.assertEqual(args[args.index("--proto") + 1], "=https")
        self.assertEqual(args[args.index("--proto-redir") + 1], "=https")
        self.assertEqual(args[-1], "https://github.com/trufflesecurity/trufflehog/releases/"
                         "download/v3.97.8/trufflehog_3.97.8_darwin_arm64.tar.gz")

    def test_hash_mismatch_fails_before_extraction_or_installation(self):
        self.stub("tar", 'touch "$RUNNER_TEMP/extraction-was-attempted"\nexit 1\n')
        result = self.run_installer(FIXTURE_EXPECTED_HASH="0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.runner.iterdir()), [])
        self.assertEqual(self.github_path.read_bytes(), b"")

    def test_requires_ci_before_download(self):
        result = self.run_installer(CI="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "curl_args").exists())
        self.assertEqual(list(self.runner.iterdir()), [])
