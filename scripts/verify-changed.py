#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: 2026 ugfugl.io

"""Print run or skip after classification so errors never authorize a skip.
Only documentation and website changes skip the build; hooks, lint, SPDX and release-tool tests always run."""

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
    print("run" if must_build(sys.stdin) else "skip")
