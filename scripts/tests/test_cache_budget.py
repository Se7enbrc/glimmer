# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Cache capacity is optional; unavailable storage must not bypass verification."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('cache_budget', ROOT / 'scripts/cache-budget.py')
budget = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budget)


class CacheBudgetTests(unittest.TestCase):
    def test_only_shared_trusted_branches_may_write(self):
        for ref in ('refs/pull/196/merge', 'refs/heads/feature', 'refs/tags/2026.10.8'):
            self.assertFalse(budget.admitted(ref, 'push', 1, 0))
        for ref in ('refs/heads/main', 'refs/heads/release-candidate'):
            self.assertTrue(budget.admitted(ref, 'workflow_dispatch', 1, 0))
            self.assertFalse(budget.admitted(ref, 'pull_request_target', 1, 0))

    def test_limits_leave_room_for_concurrent_uploads(self):
        self.assertEqual(budget.ENTRY_LIMIT, 512 * 1024**2)
        self.assertEqual(budget.REPOSITORY_LIMIT, 5 * 1024**3)
        self.assertTrue(budget.admitted('refs/heads/main', 'push', budget.ENTRY_LIMIT,
                                        budget.REPOSITORY_LIMIT - 1))
        for entry, used in ((0, 0), (budget.ENTRY_LIMIT + 1, 0), (1, budget.REPOSITORY_LIMIT), (1, -1)):
            self.assertFalse(budget.admitted('refs/heads/main', 'push', entry, used))

    def test_size_counts_payload_without_following_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / 'cache'
            cache.mkdir()
            (cache / 'object').write_bytes(b'12345')
            outside = root / 'outside'
            outside.mkdir()
            (outside / 'large').write_bytes(b'x' * 1000)
            (cache / 'link').symlink_to(outside, target_is_directory=True)
            self.assertEqual(budget.cache_size([cache, root / 'absent']), 5)
            with self.assertRaises(ValueError):
                budget.cache_size([cache / 'link'])

    def test_unreadable_usage_skips_upload(self):
        env = {'GITHUB_REF': 'refs/heads/main', 'GITHUB_EVENT_NAME': 'push',
               'CACHE_PATHS': '.', 'GITHUB_REPOSITORY': 'owner/repo'}
        with patch.dict(os.environ, env), patch.object(budget, 'cache_size', return_value=100), \
                patch.object(budget.subprocess, 'run', side_effect=OSError), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            budget.main()
        self.assertEqual(output.getvalue(), 'save=false\n')

    def test_pr_never_queries_or_uploads_cache(self):
        with patch.dict(os.environ, GITHUB_REF='refs/pull/196/merge', GITHUB_EVENT_NAME='pull_request'), \
                patch.object(budget.subprocess, 'run') as run, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            budget.main()
        run.assert_not_called()
        self.assertEqual(output.getvalue(), 'save=false\n')

    def test_workflows_bound_every_build_artifact_and_keep_native_lint(self):
        import re
        for path in (ROOT / '.github/workflows').glob('*.yml'):
            for step in re.split(r'(?m)^      - name:', path.read_text()):
                if 'uses: actions/upload-artifact@' in step:
                    self.assertIn('retention-days: 1', step, path)
        checks = (ROOT / 'scripts/ci-checks.mk').read_text().split('check-macos:', 1)[1]
        self.assertIn('hk check --all --step swiftlint', checks)
        hooks = (ROOT / 'hk.pkl').read_text()
        self.assertIn('macos = "scripts/lint-swift.sh lint --strict --quiet"', hooks)
