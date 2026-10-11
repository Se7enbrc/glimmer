#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Read a pull request's changed paths on stdin; exit 0 when Verify must build and test.

Only a change made entirely of documentation and the website skips the build; the checks
part (hooks, lint, SPDX, release-tool tests) always runs."""

import re
import sys

DOCS_ONLY = re.compile(
    r"\.md$|^docs/|^website/|^index\.html$|^\.github/ISSUE_TEMPLATE/|^LICENSE$"
)


def must_build(paths):
    # An empty or unreadable list builds: skipping is the only outcome that needs proof.
    paths = [path.strip() for path in paths if path.strip()]
    return not paths or not all(DOCS_ONLY.search(path) for path in paths)


if __name__ == "__main__":
    sys.exit(0 if must_build(sys.stdin) else 1)
